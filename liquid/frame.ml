(*
 * Copyright © 2008 The Regents of the University of California. All rights reserved.
 *
 * Permission is hereby granted, without written agreement and without
 * license or royalty fees, to use, copy, modify, and distribute this
 * software and its documentation for any purpose, provided that the
 * above copyright notice and the following two paragraphs appear in
 * all copies of this software.
 *
 * IN NO EVENT SHALL THE UNIVERSITY OF CALIFORNIA BE LIABLE TO ANY PARTY
 * FOR DIRECT, INDIRECT, SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES
 * ARISING OUT OF THE USE OF THIS SOFTWARE AND ITS DOCUMENTATION, EVEN
 * IF THE UNIVERSITY OF CALIFORNIA HAS BEEN ADVISED OF THE POSSIBILITY
 * OF SUCH DAMAGE.
 *
 * THE UNIVERSITY OF CALIFORNIA SPECIFICALLY DISCLAIMS ANY WARRANTIES,
 * INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
 * AND FITNESS FOR A PARTICULAR PURPOSE. THE SOFTWARE PROVIDED HEREUNDER IS
 * ON AN "AS IS" BASIS, AND THE UNIVERSITY OF CALIFORNIA HAS NO OBLIGATION
 * TO PROVIDE MAINTENANCE, SUPPORT, UPDATES, ENHANCEMENTS, OR MODIFICATIONS.
 *
 *)

open Parsetree (* must be opened before typedtree *)
open Types
open Typedtree
open Btype
open Format
open Asttypes

open Misc.Ops

module C = Common
module PM = C.PathMap
module T = Typetexp
module Pat = Pattern
module M = Miscutil
module P = Predicate
module Le = Lightenv

(**************************************************************)
(************** Type definitions: Refinements *****************)
(**************************************************************)

type substitution = Path.t * P.pexpr
type dep_sub      = string * string

type qvar       = Path.t
type refexpr    = substitution list * (Qualifier.t list * qvar list)
type refinement = refexpr list

type 'a prerecref = 'a list list
type recref       = refinement prerecref

type qexpr =
  | Qconst of Qualifier.t
  | Qvar of qvar

type simple_refinement = substitution list * qexpr

type refinement_placeholder =
  | Refine
  | DontRefine

(**************************************************************)
(***************** Type definitions: Frames *******************)
(**************************************************************)

type 'a preframe =
  | Fvar       of Path.t * int * dep_sub list * 'a
  | Fsum       of Path.t * 'a preconstr list * 'a
  | Finductive of Path.t * Path.t list * 'a preframe list * 'a prerecref * 'a preconstr list * 'a
  | Frec       of Path.t * 'a preframe list * 'a prerecref * 'a
  | Fabstract  of Path.t * 'a preparam list * Ident.t * 'a
  | Farrow     of pattern_desc * 'a preframe * 'a preframe

and 'a preparam  = Ident.t * 'a preframe * variance
and 'a preconstr = constructor_tag * (string * 'a preparam list)
and variance     = Covariant | Contravariant | Invariant

type param  = refinement preparam
type constr = refinement preconstr

type t = refinement preframe

let path_tuple = Path.mk_ident "tuple"

exception LabelLikeFailure of t * t

(**************************************************************)
(**************** Type environments ***************************)
(**************************************************************)

(* this is a bit shady: we memoize by string only to save the compare*)
exception Found_by_name of t

let find_by_name env s =
   try (Le.iter (fun p f -> if Path.name p = s then raise (Found_by_name f)) env; raise Not_found)
    with Found_by_name t -> t 

let prune_env_funs env = Le.fold (fun p f xs -> (function Farrow _ -> xs | _ -> p :: xs) f) env []

let env_ignore_list = ["Pervasives"; "Open_"; "FP_"; "false"; "true"; "Array"; "String"; "Big"; "None"; "Some"; "Random"; "[]"; "()"]

let prune_background env = Le.filter
  (fun p _ -> 
    let p = Path.name p in
    List.for_all (fun pre -> not(C.has_prefix pre p)) env_ignore_list && not(C.tmpstring p)) env

(**************************************************************)
(**************** Constructed type accessors ******************)
(**************************************************************)

let params_frames ps =
  List.map (fun (_, f, _) -> f) ps

let params_ids ps =
  List.map (fun (i, _, _) -> i) ps

let constr_params (_, (_, p)) =
  p

let constr_param_frames c =
  params_frames (constr_params c)

let constr_app_params f (t, (n, ps)) =
  (t, (n, f ps))

let constr_app_params2 f (t, (n, ps1)) (_, (_, ps2)) =
  (t, (n, f ps1 ps2))

let constrs_tag_params t cs =
  snd (List.assoc t cs)

let record_field f n = match f with
  | Fsum (_, [c], _) -> List.nth (constr_param_frames c) n
  | _                -> failwith "record_field called on non-record"

(**************************************************************)
(************************* Iterators **************************) 
(**************************************************************)

let apply_params_frames f ps =
  List.map (fun (p, fr, v) -> (p, f fr, v)) ps

let apply_constrs_params_frames f cs =
  List.map (constr_app_params (apply_params_frames f)) cs

let rec map f = function
  | (Fvar _ | Frec _) as fr             -> f fr
  | Fsum (p, cs, r)                     -> f (Fsum (p,  apply_constrs_params_frames (map f) cs, r))
  | Finductive (p, tfs, tas, rr, cs, r) -> f (Finductive (p, tfs, List.map (map f) tas, rr, apply_constrs_params_frames (map f) cs, r))
  | Fabstract (p, ps, id, r)            -> f (Fabstract (p, map_params f ps, id, r))
  | Farrow (x, f1, f2)                  -> f (Farrow (x, map f f1, map f f2))

and map_params f ps =
  apply_params_frames (map f) ps

let rec map_labels f fr = 
  map (map_label_map f) fr

and map_label_map f = function
    Farrow (x, a, b) -> Farrow (f x, a, b)
  | Fabstract (p, ps, id, r) ->
      let id = if C.empty_list ps then id else
        (List.hd (Typedtree.pat_desc_bound_idents (f (Tpat_var id)))) in
        Fabstract(p, map_param_labels f ps, id, r)
  | fr -> fr

and map_param_labels f ps =
  let i2p i = Tpat_var i in
    List.map (fun (i, fr, v) -> (List.hd (Typedtree.pat_desc_bound_idents (f (i2p i))), map_labels f fr, v)) ps  

let rec iter_labels f fr =
  let f' p = f p; p in
    ignore (map_labels f' fr)

let map_recref f rr =
  List.map (fun r -> List.map f r) rr

let rec map_refinements f = function
  | Frec (p, tas, rr, r)                -> Frec (p, List.map (map_refinements f) tas, map_recref f rr, f r)
  | Fvar (p, level, s, r)               -> Fvar (p, level, s, f r)
  | Fsum (p, cs, r)                     -> Fsum (p, apply_constrs_params_frames (map_refinements f) cs, f r)
  | Finductive (p, tfs, tas, rr, cs, r) -> Finductive (p, tfs, List.map (map_refinements f) tas, map_recref f rr, apply_constrs_params_frames (map_refinements f) cs, f r)
  | Fabstract (p, ps, id, r)            -> Fabstract (p, apply_params_frames (map_refinements f) ps, id, f r)
  | Farrow (pat, f1, f2)                -> Farrow (pat, map_refinements f f1, map_refinements f f2)

let map_refexprs f fr =
  map_refinements (fun r -> List.map f r) fr

let map_qualifiers f fr =
  map_refexprs (fun (subs, (qs, vs)) -> (subs, (List.rev_map f qs, vs))) fr

let recref_fold f rr l =
  List.fold_right f (List.flatten rr) l

let recref_iter f rr =
  List.iter f (List.flatten rr)

let rec refinement_fold f l = function
  | Frec (_, _, rr, r) -> f r (recref_fold f rr l)
  | Fvar (_, _, s, r) -> f r l
  | Fsum (_, cs, r) ->
      (* pmr: abstract out the following *)
      f r (List.fold_left (refinement_fold f) l (C.flap constr_param_frames cs))
  | Finductive (_, _, _, rr, cs, r) ->
      f r (List.fold_left (refinement_fold f) (recref_fold f rr l) (C.flap constr_param_frames cs))
  | Fabstract (_, ps, _, r) ->
      f r (List.fold_left (refinement_fold f) l (params_frames ps))
  | Farrow (_, f1, f2) ->
      refinement_fold f (refinement_fold f l f1) f2

let rec refinement_iter f = function
  | Frec (_, _, rr, r)              -> recref_iter f rr; f r
  | Fvar (_, _, s, r)               -> f r
  | Fsum (_, cs, r)                 -> f r; List.iter (refinement_iter f) (C.flap constr_param_frames cs)
  | Finductive (_, _, _, rr, cs, r) -> recref_iter f rr; List.iter (refinement_iter f) (C.flap constr_param_frames cs); f r
  | Fabstract (_, ps, _, r)         -> List.iter (refinement_iter f) (params_frames ps); f r
  | Farrow (_, f1, f2)              -> refinement_iter f f1; refinement_iter f f2

(******************************************************************************)
(*************************** Type level manipulation **************************)
(******************************************************************************)

let generic_level = -Btype.generic_level

let current_level = ref (-1)

let uninitialized_level = 0

let rec initialize_type_expr_levels t =
  let t = repr t in
    if t.level >= uninitialized_level then t.level <- !current_level;
    Btype.iter_type_expr initialize_type_expr_levels t

let begin_def () =
  decr current_level

let end_def () =
  incr current_level

let generalize_map = function
  | Fvar (p, level, s, r) ->
      let level = if level < !current_level then generic_level else level in
        Fvar (p, level, s, r)
  | f -> f

let generalize f =
  map generalize_map f

(**************************************************************)
(****************** Refinement manipulation *******************) 
(**************************************************************)

let mk_refinement subs qconsts qvars =
  [(subs, (qconsts, qvars))]

let empty_refinement =
  mk_refinement [] [] []

let const_refinement qs =
  mk_refinement [] qs []

let refinement_is_empty qes =
  List.for_all (function (_, ([], [])) -> true | _ -> false) qes

let recref_is_empty rr =
  List.for_all (List.for_all refinement_is_empty) rr

let false_refinement =
  mk_refinement [] [(Path.mk_ident "false", Path.mk_ident "V", P.Not (P.True))] []

let apply_refinement r = function
  | Fvar (p, level, s, _)               -> Fvar (p, level, s, r)
  | Fsum (p, cs, _)                     -> Fsum (p, cs, r)
  | Finductive (p, tfs, tas, rr, cs, _) -> Finductive (p, tfs, tas, rr, cs, r)
  | Fabstract (p, ps, id, _)            -> Fabstract (p, ps, id, r)
  | Frec (p, tas, rr, _)                -> Frec (p, tas, rr, r)
  | f                                   -> f

  (*need to apply subs when refinement is pulled somehow..*)
let get_refinement = function
  | Fvar (_, _, _, r) | Fsum (_, _, r)
  | Finductive (_, _, _, _, _, r)
  | Frec (_, _, _, r) | Fabstract (_, _, _, r) -> Some r
  | _                                          -> None

let append_refinement res' f =
  match get_refinement f with
    | Some res -> apply_refinement (res @ res') f
    | None     -> f

let set_recref rr = function
  | Frec (p, tas, _, r)                -> Frec (p, tas, rr, r)
  | Finductive (p, tfs, tas, _, cs, r) -> Finductive (p, tfs, tas, rr, cs, r)
  | _                                  -> assert false

let get_recref = function
  | Frec (_, _, rr, _) | Finductive (_, _, _, rr, _, _) -> Some rr
  | _                                                   -> None

let merge_recrefs rr rr' =
  List.map2 (List.map2 (@)) rr rr'

let append_recref rr' f = match get_recref f with
  | Some rr -> set_recref (merge_recrefs rr rr') f
  | None    -> f

let eager_apply subs qs =
  List.rev_map (Qualifier.map_pred (C.app_snd (P.apply_substs subs))) qs 

let refexpr_apply_subs subs' (subs, qexprs) =
  match qexprs with
  | (qconsts, [])    -> (subs, (eager_apply subs' qconsts, []))
  | (qconsts, qvars) -> (subs' @ subs, qexprs)

let apply_subs subs f =
  map_refexprs (refexpr_apply_subs subs) f

let refinement_qvars r =
  C.flap (fun (_, (_, qvars)) -> qvars) r

exception Found

let has_kvars f = 
  try ignore (map_refinements 
    (fun r -> if not (C.empty_list (refinement_qvars r)) then raise Found; r)
      f); false with Found -> true

(**************************************************************)
(*********** Conversions to/from simple refinements ***********)
(**************************************************************)

let split_refexpr (qc, qv) (subs, (qconsts, qvars)) =
  (qc @ List.map (fun q -> (subs, Qconst q)) qconsts,
   qv @ List.map (fun k -> (subs, Qvar k)) qvars)

let ref_to_simples r =
  List.fold_left split_refexpr ([], []) r

let ref_of_simple = function
  | (subs, Qconst q) -> mk_refinement subs [q] []
  | (subs, Qvar v)   -> mk_refinement subs [] [v]

(******************************************************************************)
(****************************** Constructor tags ******************************)
(******************************************************************************)

let maybe_tag_qualifier (_, v, pred) =
  match pred with
     P.Atom (P.FunApp (tag_fun, [(P.Var v')]), P.Eq, P.PInt t) when v = v' && tag_fun = P.tag_function -> Some (C.tag_of_int t)
   | _ -> None

let find_tag_single ts r =
  let (_, (qs, _)) = r in
    (C.maybe_list (List.map maybe_tag_qualifier qs)) @ ts

let find_tag rs =
  C.only_one "too many tags in constructed value" (List.fold_left find_tag_single [] rs)

(**************************************************************)
(************************* Shapes *****************************) 
(**************************************************************)

let shape f =
  map_refinements (fun _ -> empty_refinement) f

let is_shape f =
  refinement_fold (fun r b -> refinement_is_empty r && b) true f

(* known bug: these don't treat constructor names properly. *)

let same_shape t1 t2 =
  let vars = ref [] in
  let ismapped p q = try snd (List.find (fun (p', _) -> Path.same p p') !vars) = q with
      Not_found -> vars := (p, q) :: !vars; true in
  let rec sshape = function
      (Fsum(p, cs, _), Fsum(p', cs', _)) ->
        Path.same p p' && params_sshape (C.flap constr_params cs) (C.flap constr_params cs')
    | (Fabstract(p, ps, _, _), Fabstract(p', ps', _, _)) ->
        Path.same p p' && params_sshape ps ps'
    | (Fvar (p, _, _, _), Fvar (p', _, _, _)) ->
        ismapped p p'
    | (Frec (p, tas, _, _), Frec (p', tas', _, _)) ->
        ismapped p p' && C.same_length tas tas' && List.for_all sshape (List.combine tas tas')
    | (Farrow(_, i, o), Farrow(_, i', o')) ->
        sshape (i, i') && sshape (o, o')
    | t -> false
  and params_sshape ps qs =
    C.same_length ps qs && List.for_all sshape (List.combine (params_frames ps) (params_frames qs))
  in sshape (t1, t2)
       
let fid () = Path.mk_ident "p"
let maybe_assoc p l =
  try
    Some (List.assoc p l) 
  with Not_found -> None

let rec subt t1 t2 eq inst =
  (* yes, i inlined a union find :( *)
  let map = ref inst in
  let pmap = ref eq in
  let get_ind p =
    try
      List.assoc p !pmap
    with Not_found -> 
      let p' = fid () in 
      let _ = pmap := (p, p') :: !pmap in
        p' in
  let get_set p =
    let p' = get_ind p in
    List.filter (fun (x, y) -> y = p') !pmap in
  let ismapped p f =
    let p' = get_ind p in
    try
      same_shape (List.assoc p' !map) f
    with Not_found -> (map := (p', f) :: !map; true) in
  let join p' q' =
    pmap := ((List.map (fun (x, _) -> (x, p')) (get_set q')) @ !pmap) in
  let equiv p q =
    let p' = get_ind p in
    let q' = get_ind q in
    if p' = q' then true else
      match (maybe_assoc p' !map, maybe_assoc q' !map) with
          (Some f1, Some f2) -> 
          if same_shape f1 f2 then
            let _ = join p' q' in true
            else false
        | (None, Some f) | (Some f, None) ->
          let _ = map := ((p', f) :: !map) in
          let _ = join p' q' in true
        | (None, None) ->
          let _ = join p' q' in true in
  let rec s_rec (f1, f2) = 
    match (f1, f2) with
    | (Fsum(p, cs, _), Fsum(p', cs', _)) ->
        Path.same p p' && p_s (C.flap constr_params cs) (C.flap constr_params cs')
    | (Fabstract(p, ps, _, _), Fabstract(p', ps', _, _)) ->
        Path.same p p' && p_s ps ps'
    | (Frec(p, tas, rr, _), Frec(p', tas', rr', _)) ->
        rr = rr' && Path.same p p' && C.same_length tas tas' && List.for_all s_rec (List.combine tas tas')
    | (Frec(_, _, _, _), _) ->
        false
        (* s_rec (f2, t1) *)
    | (_, Frec(_, _, _, _)) ->
        (*assert*) false (* assume that the LHS is folded up *)
    | (Fvar(p1, _, _, _), Fvar(p2, _, _, _)) ->
        equiv p1 p2
    | (Fvar(p, _, _, _), _) -> 
        ismapped p f2
    | (Farrow(_, i, o), Farrow(_, i', o')) ->
        s_rec(i, i') && s_rec(o, o')
    | t -> false 
  and p_s ps qs =
    List.for_all s_rec (List.combine (params_frames ps) (params_frames qs)) in
  (s_rec (t1, t2), !pmap, !map) (* relies on deterministic o of eval *)

let subti t1 t2 =
  subt t1 t2 [] []

let subtis t1 t2 =
  (fun (x, _, _) -> x) (subti t1 t2)

let map_inst eq inst f =
  let get_ind p =
    try List.assoc p eq with Not_found -> p in
  let mapped p =
    let p = get_ind p in
    try
      Some (List.assoc p inst)
    with Not_found -> None in
  let m_inst = function
    | Fvar (p, _, _, _) as ofr -> (match mapped p with Some fr -> fr | None -> ofr)
    | fr -> fr in 
  map m_inst f

(**************************************************************)
(******************** Frame pretty printers *******************)
(**************************************************************)

let top_sym = "⊤"

let bot_sym = "⊥"

let pprint_sub ppf (path, pexp) =
  fprintf ppf "@[(%s@ ->@ %a)@]" (Path.unique_name path) P.pprint_pexpr pexp

let pred_of_qual subs q =
  let p = Qualifier.apply (P.Var (Path.mk_ident "V")) q in
  P.apply_substs subs p

let flatten_refinement res = 
  List.fold_left 
    (fun (ps, svs) (s, (qs, vs)) -> 
      (ps @ (List.map (pred_of_qual s) qs)), 
      (svs @ (List.map (fun v -> (s,v)) vs)))
    ([],[]) res

let pprint_psub ppf (s, v) =
  if !Clflags.print_subs then
    fprintf ppf "[%a] %s" (C.pprint_many false " " pprint_sub) s (C.path_name v) 
  else
    fprintf ppf "%s" (C.path_name v) 

let pprint_refinement ppf res = 
  match flatten_refinement res with
  | [], []  -> 
      fprintf ppf "%s" top_sym
  | ps, _ when List.exists P.is_contra ps ->  
      fprintf ppf "%s" bot_sym
  | ps, svs -> 
      fprintf ppf "@[<hv 0>%a%a@]" 
        (C.pprint_many true "" P.pprint) ps 
        (C.pprint_many false ""  pprint_psub) svs 

let rec pprint_pattern ppf = function
  | Tpat_any -> 
      fprintf ppf "_"
  | Tpat_var x -> 
      fprintf ppf "%s" (C.ident_name x)
  | Tpat_tuple pats -> 
      fprintf ppf "(%a)" pprint_pattern_list pats 
  | Tpat_construct (cstrdesc, pats) ->
      begin match (repr cstrdesc.cstr_res).desc with
        | Tconstr (p, _, _) -> 
            fprintf ppf "%s(%a)" (Path.name p) pprint_pattern_list pats
        | _ -> assert false end
  | _ -> assert false

and pprint_pattern_list ppf pats =
  let ds = List.map (fun p -> p.pat_desc) pats in
  C.pprint_many false "," pprint_pattern ppf ds 

let wrap_refined r ppf pp =
  if List.for_all (function (_, ([], [])) -> true | _ -> false) r then
    (fprintf ppf "@["; pp ppf; fprintf ppf "@]")
  else
    (fprintf ppf "@[{"; pp ppf; fprintf ppf " |@ %a}@]" pprint_refinement r)

let pprint_refs ppf rs =
  fprintf ppf "‹@[%a›@]" (C.pprint_many false "," pprint_refinement) rs

let pprint_recref ppf rr =
  let lp, rp  = "«", "»" in 
  if not (recref_is_empty rr) 
  then fprintf ppf "%s@[%a%s@]" lp (C.pprint_many false "," pprint_refs) rr rp

let level_suffix l = 
  if l = generic_level then "P" else "M"

let rec pprint ppf = function
  | Frec (path, tas, rr, r) ->
      wrap_refined r ppf 
      (fun ppf -> fprintf ppf "@[%a (%a) %s@]" pprint_recref rr (C.pprint_many true "," pprint) tas (C.path_name path))
  | Fvar (a, level, s, r) ->
      wrap_refined r ppf 
      (fun ppf -> fprintf ppf "'%s%s%a" (C.path_name a) (level_suffix level) 
                  (C.pprint_many false "" (fun ppf (s, s') -> fprintf ppf "[%s/%s]" s s')) s)  
  | Fsum (path, cs, r) ->
      wrap_refined r ppf 
      (fun ppf -> fprintf ppf "%s. @[<hv 0>%a@]" (C.path_name path) print_sum cs)
  | Finductive (path, _, tas, _, cs, r) when !Clflags.hide_rectypes ->
      let la, ra  = "«", "»" in 
      wrap_refined r ppf 
      (fun ppf -> fprintf ppf "%s@[%a@] %s%s. @[<hv 0>%a@]" la (C.pprint_many false "," pprint) tas (C.path_name path) ra print_sum cs)
  | Finductive (path, tfs, tas, rr, cs, r) ->
      let la, ra  = "«", "»" in 
      wrap_refined r ppf 
      (fun ppf -> fprintf ppf "<%a> %s@[%a |-> %a@] %s%s. @[<hv 0>%a@]" pprint_recref rr la  (C.pprint_many false "," (fun ppf p -> Format.fprintf ppf "%s" (Path.unique_name p))) tfs (C.pprint_many false "," pprint) tas (C.path_name path) ra print_sum cs)
  | Farrow (pat, f, f') -> 
      fprintf ppf "@[<hv 0>(%a:%a) ->@ %a@]" pprint_pattern pat pprint f pprint f'
  | Fabstract (path, [], id, r) ->
      wrap_refined r ppf 
      (fun ppf -> fprintf ppf "@[%s@]" (C.path_name path)) 
  | Fabstract (path, params, id, r) ->
      wrap_refined r ppf 
      (fun ppf -> fprintf ppf "@[%s: %a %s@]"
                  (C.path_name (C.i2p id)) print_prd params (C.path_name path)) 

and print_sum ppf = function
  | [] -> ()
  | cs -> fprintf ppf "@[<hv 0>%a@]" (C.pprint_many true "+" pprint_constructor) cs

and print_prd ppf = function
  | []  -> ()
  | prd -> fprintf ppf "(@[<hv 0>%a)@]" (C.pprint_many true "," print_bind) prd

and pprint_constructor ppf (_, (n, ps)) = 
   fprintf ppf "%s%a" n print_prd ps

and print_bind ppf (name, f, _) = 
   fprintf ppf "%s:%a" (C.ident_name name) pprint f
 
let rec pprint_fenv ppf fenv =
  Lightenv.maplist (fun k v -> printf "@[%s:@ %a@]@." (C.path_name k) pprint v) fenv

(******************************************************************************)
(********************************** Unfolding *********************************)
(******************************************************************************)

let rec apply_refs rs ps = match (rs, ps) with
  | (r :: rs, (i, f, v) :: ps) ->
      let (ip, i') = (Path.Pident i, Ident.create (Ident.name i)) in
      let sub      = (ip, P.Var (Path.Pident i')) in
      let ps       = List.map (fun (i, f, v) -> (i, apply_subs [sub] f, v)) ps in
      let rs       = List.map (List.map (refexpr_apply_subs [sub])) rs in
        (i', append_refinement r f, v) :: apply_refs rs ps
  | ([], []) -> []
  | _        -> assert false

let apply_recref_constrs rr cs =
   List.map2 (fun rs -> constr_app_params (apply_refs rs)) rr cs
 
let apply_recref rr = function
  | Fsum (p, cs, r) -> Fsum (p, apply_recref_constrs rr cs, r)
  | _               -> assert false

(* pmr: review these on paper *)
let replace_recvar p tfs rr cs = function
  | Frec (rp, tas, rr', r) when Path.same p rp -> Finductive (p, tfs, tas, merge_recrefs rr rr', cs, r)
  | f                                          -> f

(* lift with inner definition *)
let rec replace_typevars merge_refinements vmap = function
  | Fvar (p, _, dsubs, r) as f ->
      begin try
        merge_refinements r (List.assoc p vmap)
      with Not_found ->
        f
      end
  | Fsum (p, cs, r)                     -> Fsum (p, apply_constrs_params_frames (replace_typevars merge_refinements vmap) cs, r)
  | Finductive (p, tfs, tas, rr, cs, r) -> Finductive (p, tfs, List.map (replace_typevars merge_refinements vmap) tas, rr, cs, r)
  | Frec (p, tas, rr, r)                -> Frec (p, List.map (replace_typevars merge_refinements vmap) tas, rr, r)
  | Fabstract (p, ps, id, r)            -> Fabstract (p, apply_params_frames (replace_typevars merge_refinements vmap) ps, id, r)
  | Farrow (pat, f, f')                 -> Farrow (pat, replace_typevars merge_refinements vmap f, replace_typevars merge_refinements vmap f')

(* need two types of unfold:
   - with propagating recrefs (normal use)
   - propagating just the shape of the type, no recrefs (constraint use)
*)
let unfold = function
  | Finductive (p, tfs, tas, rr, cs, r) ->
       Fsum (p, cs, r)
    |> apply_recref rr
    |> map (replace_recvar p tfs rr cs)
    |> replace_typevars append_refinement (List.combine tfs tas)
  | f -> f
(*
let unfold_with_shape = function
  | Finductive (p, tfs, tas, rr, cs, r) ->
  | f                                -> f
*)
(**************************************************************)
(********* Polymorphic and qualifier instantiation ************) 
(**************************************************************)

type bind = Bpat of pattern_desc | Bid of Ident.t

let dep_sub_to_sub binds scbinds env (s, s') =
  let i2sub i = (Ident.name i, C.i2p i) in
  let bind = function
    | Bpat p -> List.map i2sub (Typedtree.pat_desc_bound_idents p)
    | Bid i -> [i2sub i] in
  let binds = C.flap bind binds in
  let scbinds = C.flap bind scbinds in
  let c i =
    try List.assoc i binds
      with Not_found -> Le.find_path i env in
  try (c s', P.Var (List.assoc s scbinds))
    with Not_found -> failwith (sprintf "Could not bind dependent substitution %s to paths" s)

let apply_dep_subs subs = function
    Fvar (p, i, _, r) -> Fvar (p, i, subs, r)
  | _                 -> assert false

let instantiate_dep_subs vars subs =
  let c i =
    try Path.name (List.assoc i vars) with Not_found -> i in
  List.map (C.app_pr c) subs
  
(* Instantiate the tyvars in fr with the corresponding frames in ftemplate.
   If a variable occurs twice, it will only be instantiated with one frame; which
   one is undefined and unimportant. *)
let instantiate env fr ftemplate =
  let binds = ref [] in
  let vars  = ref [] in
  let vmap p ft =
    try List.assoc p !vars with Not_found -> vars := (p, ft) :: !vars; ft in
  let rec inst scbinds f ft =
    match (f, ft) with
      | (Fvar (p, level, s, r), _) when level = generic_level ->
          let instf = vmap p ft in 
          let subs  = List.map (dep_sub_to_sub !binds scbinds env) s in
          apply_subs subs (append_refinement r instf)
      | (Fvar _, _) ->
          f
      | (Frec (p, tas1, rr, r), Frec (_, tas2, _, _)) ->
          Frec (p, List.map2 (inst scbinds) tas1 tas2, rr, r)
      | (Farrow (l, f1, f1'), Farrow (_, f2, f2')) ->
          let nf1 = inst scbinds f1 f2 in
          let _   = binds := (Bpat l) :: !binds in
          let nf2 = inst ((Bpat l) :: scbinds) f1' f2' in
          Farrow (l, nf1, nf2)
      | (Fsum (p, cs, r), Fsum(p', cs', _)) ->
          Fsum (p, List.map2 (constr_app_params2 (inst_params scbinds)) cs cs', r)
      | (Finductive (p, tfs, tas1, rr, cs, r), Finductive (_, _, tas2, _, _, _)) ->
          Finductive (p, tfs, List.map2 (inst scbinds) tas1 tas2, rr, cs, r)
      | (Fabstract(p, ps, id, r), Fabstract(_, ps', _, _)) ->
          let _ = binds := (Bid id) :: !binds in
          Fabstract (p, inst_params ((Bid id) :: scbinds) ps ps', id, r)
      | (f1, f2) ->
          fprintf std_formatter "@[Unsupported@ types@ for@ instantiation:@;<1 2>%a@;<1 2>%a@]@."
	    pprint f1 pprint f2;
	    raise (Failure ("Instantiate"))
  and inst_params scbinds ps ps' =
    let bind_param (ps, scbinds) (p, f, v) (_, f', _) =
      binds := (Bid p) :: !binds;
      ((ps @ [(p, inst scbinds f f', v)]), (Bid p) :: scbinds) in
    fst (List.fold_left2 bind_param ([], scbinds) ps ps')
  in inst [] fr ftemplate

let instantiate_refexpr_qualifiers vars (subs, (qconsts, qvars)) =
  (subs, (List.map (fun q -> match Qualifier.instantiate vars q with Some q -> q | None -> q) qconsts, qvars))

let instantiate_ref_qualifiers vars r =
  List.map (instantiate_refexpr_qualifiers vars) r

let instantiate_recref_qualifiers vars rr =
  List.map (fun r -> List.map (instantiate_ref_qualifiers vars) r) rr

let instantiate_qualifiers vars fr =
  map_refexprs (instantiate_refexpr_qualifiers vars) fr

(**************************************************************)
(********************* Argument labeling **********************) 
(**************************************************************)

(* Label all the formals in [f] with their corresponding labels in
   [f'] and changing constant qualifiers appropriately.
   [f] and [f'] are expected to be of the same shape; also, [f]
   must be completely unlabeled (as frames are after creation by fresh). *)
let label_like f f' =
  let rec label vars f f' = match (f, f') with
    | (Fvar _, Fvar (_, _, s, _)) ->
        instantiate_qualifiers vars (apply_dep_subs (instantiate_dep_subs vars s) f) 
    | (Frec _, Frec _) ->
        instantiate_qualifiers vars f
    | (Fsum (p, cs1, r), Fsum (_, cs2, _)) ->
        Fsum (p, label_constrs_like vars cs1 cs2, instantiate_ref_qualifiers vars r)
    | (Finductive (p, tfs, tas, rr, cs1, r), Finductive (_, _, _, _, cs2, _)) ->
        Finductive (p, tfs, tas, instantiate_recref_qualifiers vars rr,
                 label_constrs_like vars cs1 cs2, instantiate_ref_qualifiers vars r)
    | (Fabstract (p, ps, id, r), Fabstract (_, ps', id', _)) ->
        let vars' = (Ident.name id, Path.Pident id') :: vars in
          Fabstract (p, label_params_like vars' ps ps', id', instantiate_ref_qualifiers vars r)
    | (Farrow (p1, f1, f1'), Farrow (p2, f2, f2')) ->
        let vars' = List.map (fun (x, y) -> (Ident.name x, Path.Pident y)) (Pattern.bind_vars p1 p2) @ vars in
          Farrow (p2, label vars f1 f2, label vars' f1' f2')
    | _ -> printf "@[Can't label %a like %a@.@]" pprint f pprint f'; raise (LabelLikeFailure(f, f'))
  and label_constrs_like vars cs1 cs2 =
    List.map2 (constr_app_params2 (label_params_like vars)) cs1 cs2
  and label_params_like vars ps1 ps2 = match (ps1, ps2) with
    | ([], []) -> []
    | ((i1, f1, v1) :: ps1, (i2, f2, _) :: ps2) ->
        let f1 = label vars f1 f2 in
        let vars = (Ident.name i1, Path.Pident i2) :: vars in
          (i2, f1, v1) :: label_params_like vars ps1 ps2
    | ([], x :: xs)
    | (x :: xs, []) -> raise (Failure "Label_like param mismatch")
  in label [] f f'

let sum_of_params path ps r =
  Fsum (path, [(Cstr_constant 0, ("rec", ps))], r)

let abstract_of_params_with_labels labels p params varis id r =
  Fabstract (p, C.combine3 labels params varis, id, r)

let abstract_of_params p params varis r =
  let id = if C.empty_list params then C.dummy_id else C.abstr_elem_id () in
  Fabstract (p, C.combine3 (Miscutil.mapi (fun _ i -> C.tuple_elem_id i) params) params varis, id, r)

let tuple_of_frames fs r =
  sum_of_params path_tuple (Miscutil.mapi (fun f i -> (C.tuple_elem_id i, f, Covariant)) fs) r

(******************************************************************************)
(**************************** Function application ****************************)
(******************************************************************************)

let apply_once f e = match f with
  | Farrow (p, f, f') -> apply_subs (Pattern.bind_pexpr p e) f'
  | _                 -> invalid_arg "apply called with non-function argument"

let apply f es =
  List.fold_left apply_once f es

(******************************************************************************)
(***************************** ML Type Translation ****************************)
(******************************************************************************)

let translate_variance = function
  | (true, true, true)   -> Invariant
  | (true, false, false) -> Covariant
  | (false, true, false) -> Contravariant
  | (a, b, c)            -> printf "@[Got gibberish variance (%b, %b, %b)@]@." a b c; assert false

let mutable_variance = function
  | Mutable -> Invariant
  | _       -> Covariant

let fresh_refinementvar () =
  mk_refinement [] [] [Path.mk_ident "k"]

let fresh_fvar level r =
  Fvar (Path.mk_ident "a", level, [], r)

let mk_constr_recref cstrs =
  List.map begin
    fun (_, params) -> List.map (fun _ -> if !Clflags.no_recrefs then DontRefine else Refine) params
  end cstrs

let mk_record_recref fields =
  [List.map (fun _ -> Refine) fields]

(* pmr: this all looks rather suspect - define fresh_binder inside transl? *)
let first_binder = Char.code 'a' - 1

let next_binder = ref first_binder

let reset_binders () = next_binder := first_binder

let fresh_binder () =
  incr next_binder; Tpat_var (Ident.create (Char.escaped (Char.chr !next_binder)))

let tconstr_params t =
  match (repr t).desc with
    | Tconstr (_, ts, _) -> ts
    | _                  -> assert false

let frame_var = function
  | Fvar (p, _, _, _) -> p
  | _                 -> failwith "frame_var called with non-var frame"

let replace_formals fps fs =
  replace_typevars (fun _ f -> f) (List.combine fps fs)

let translate_type env t =
  let tbl = Hashtbl.create 17 in

  let rec transl vstack r t =
    let t = repr t in
      try
        Hashtbl.find tbl t
      with Not_found ->
        t |> transl_rec vstack r t.level >> Hashtbl.add tbl t

  and transl_rec vstack r level t = match t.desc with
    | Tvar                 -> fresh_fvar level r
    | Tarrow(_, t1, t2, _) -> Farrow (fresh_binder (), transl vstack r t1, transl vstack r t2)
    | Ttuple ts            -> tuple_of_frames (List.map (transl vstack r) ts) r
    | Tconstr(p, tyl, _)   -> transl_constr vstack r p tyl
    | _                    -> failwith "@[Error: Translating unsupported type]@."

  and transl_constr vstack r p tyl =
    let tas = List.map (transl vstack r) tyl in
      try
        Frec (p, tas, List.assoc p vstack, r)
      with Not_found ->
        let ty_decl = Env.find_type p env in
        let tfs     = List.map (transl vstack DontRefine) ty_decl.type_params in
        let tfps    = List.map frame_var tfs in
          match ty_decl.type_kind with
            | Type_abstract              -> abstract_of_params p tas (List.map translate_variance ty_decl.type_variance) r
            | Type_record (fields, _, _) -> transl_record vstack r p fields tfps tas
            | Type_variant (cdecls, _)   -> transl_variant vstack r p cdecls tfps tfs tas

  and transl_formals vstack tys =
    List.map (fun t -> frame_var (transl vstack DontRefine t)) tys

  and transl_record vstack r p fields tfps tas =
    let rr     = mk_record_recref fields in
    let vstack = (p, rr) :: vstack in
    let ps     = List.map (transl_field vstack) fields in
      Finductive (p, tfps, tas, rr, [(Cstr_constant 0, ("rec", ps))], r)

  and transl_field vstack (name, muta, t) =
    (Ident.create name, transl vstack DontRefine t, mutable_variance muta)

  and transl_variant vstack r p cdecls tfps tfs tas =
    let names, _ = List.split cdecls in
    let _, cds   = List.split (Env.constructors_of_type p (Env.find_type p env)) in
    let rr       = mk_constr_recref cdecls in
    let vstack   = (p,  rr) :: vstack in
      Finductive (p, tfps, tas, rr, List.map2 (transl_constructor vstack tfs) names cds, r)

  and transl_constructor vstack tfs name cstr =
    let args, res = Ctype.instance_constructor cstr in
    let tfps      = res |> tconstr_params |> transl_formals vstack in
    let fs        = args |> List.map (replace_formals tfps tfs <.> transl vstack DontRefine) in
    let vs        = List.map (fun _ -> Covariant) fs in
    let ids       = Miscutil.mapi (fun _ i -> C.tuple_elem_id i) args in
      (cstr.cstr_tag, (name, C.combine3 ids fs vs))

  in transl [] Refine t

(******************************************************************************)
(******************************** Fresh Frames ********************************)
(******************************************************************************)

(* UGLY HACK ON UGLY HACK *)
let fresh_with_var_fun_get_instantiation env freshf t =
  assert false

let place_freshref freshf = function
  | Refine     -> freshf ()
  | DontRefine -> empty_refinement

let fresh_with_var_fun freshf env t =
  t |> translate_type env |> map_refinements (place_freshref freshf) >>
  Format.printf "Freshing type@.%a@.Got@.%a@." Printtyp.type_scheme t pprint

let fresh              = fresh_with_var_fun fresh_refinementvar
let fresh_false        = fresh_with_var_fun (fun _ -> false_refinement)
let fresh_without_vars = fresh_with_var_fun (fun _ -> empty_refinement)

let fresh_with_labels env ty f =
  label_like (fresh env ty) f

(* UGLY HACK *)
let fresh_constructed_params_no_vars env path paramfs =
  assert false

let rec build_uninterpreted name params = function
  | Farrow (_, f, f') ->
      let lab = Ident.create "x" in
        Farrow (Tpat_var lab, f, build_uninterpreted name (lab :: params) f')
  | f ->
      let args = List.rev_map (fun p -> P.Var (Path.Pident p)) params in
      let v    = Path.mk_ident "v" in
      let pexp = match args with [] -> P.Var name | args -> P.FunApp (name, args) in
      let r    = const_refinement [(name, v, P.Atom (P.Var v, P.Eq, pexp))] in
        apply_refinement r f

let fresh_uninterpreted env ty name =
  build_uninterpreted name [] (fresh_without_vars env ty)

(******************************************************************************)
(**************************** Constructor embedding ***************************)
(******************************************************************************)

let mk_unint_constructor f n ps =
  let frames = params_frames ps in
    build_uninterpreted n [] (List.fold_right (fun f f' -> Farrow (Tpat_var (Ident.create ""), f, f')) frames f)

let uninterpreted_constructors env ty =
  let f = fresh_without_vars env ty in
    match unfold f with
      | Fsum (_, cs, _) -> List.map (fun (_, (n, ps)) -> (n, mk_unint_constructor f (Path.mk_persistent n) ps)) cs
      | _               -> invalid_arg "uninterpreted_constructors called with non-sum type"

(**************************************************************)
(********************* Pattern binding ************************) 
(**************************************************************)

let rec bind pat frame =
  let _bind = function
    | (Tpat_any, _) ->
        ([], [])
    | (Tpat_var x, f) ->
        ([], [(Path.Pident x, f)])
    | (Tpat_alias (p, x), f) ->
        ([(p.pat_desc, f)], [(Path.Pident x, f)])
    | (Tpat_tuple pats, Fsum (_, [(_, (_, ps))], _)) ->
        ([], bind_params (Pattern.pattern_descs pats) ps)
    | (Tpat_construct (cstrdesc, pats), f) ->
        begin match unfold f with
          | Fsum (p, cfvs, _) ->
              ([], bind_params (Pattern.pattern_descs pats) (constrs_tag_params cstrdesc.cstr_tag cfvs))
          | _ -> assert false
        end
    | _ -> assert false
  in C.expand _bind [(pat, frame)] []

and bind_param (subs, binds) (i, f, _) pat =
  let f = apply_subs subs f in
  let subs =
    match pat with
      | Tpat_var x -> (Path.Pident i, P.Var (Path.Pident x)) :: subs
      | _          -> subs
  in (subs, bind pat f @ binds)

and bind_params pats params  =
  snd (List.fold_left2 bind_param ([], []) params pats)

let env_bind env pat frame =
  Lightenv.addn (bind pat frame) env

(**************************************************************)
(******************** Logical embedding ***********************) 
(**************************************************************)

let refexpr_apply_solution s (subs, (qconsts, qvars)) =
  (subs, (qconsts @ C.flap s qvars, []))

let apply_solution s f =
  map_refexprs (refexpr_apply_solution s) f

let refexpr_conjuncts s qual_expr ((subs, qexprs) as r) =
  let (_, (quals, _)) = refexpr_apply_solution s r in
    List.rev_map (C.compose (P.apply_substs subs) (Qualifier.apply qual_expr)) quals

let refinement_conjuncts s qexpr res =
  C.flap (refexpr_conjuncts s qexpr) res

let refinement_predicate s qvar refn =
  P.big_and (refinement_conjuncts s qvar refn)

let rec conjunct_fold cs s qual_expr f = match get_refinement f with
  | Some r -> refinement_conjuncts s qual_expr r @ cs
  | None   -> cs

let rec conjuncts s qexpr fr =
  conjunct_fold [] s qexpr fr

let predicate s qexpr fr =
  P.big_and (conjuncts s qexpr fr)
