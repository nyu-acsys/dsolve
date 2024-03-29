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


module BS = Bstats
module JS = Mystats
module C = Constants
module T = Types
module TT = Typedtree
module TP = TheoremProver
module B = Builtins
module Q = Lqualifier
module IM = FixMisc.IntMap
module Cf = Clflags
module S  = Consdef.Sol

module Co  = Common
module P   = Predicate
module F   = Frame
module Le  = Liqenv

module QSet = Set.Make(Q)
module NSet = Set.Make(String)

open Format
open Wellformed
open FixMisc.Ops
open Consdef

module SIM = Map.Make(struct type t = subref_id let compare = compare end)

(**************************************************************)
(**************************** Stats ***************************)
(**************************************************************)

let stat_unsat_lhs      = ref 0
let stat_wf_refines     = ref 0
let stat_sub_refines    = ref 0
let stat_simple_refines = ref 0
let stat_refines        = ref 0
let stat_imp_queries    = ref 0
let stat_valid_queries  = ref 0
let stat_matches        = ref 0
let stat_tp_refines     = ref 0

(**************************************************************)
(********************** Pretty Printing ***********************)
(**************************************************************)

let pprint_local_binding f ppf = function
  | (Path.Pident _ as k, v) -> 
      fprintf ppf "@[%s@ =>@ %a@],@;<0 2>" 
      (Path.unique_name k) f v
  | _ -> ()

let pprint_fenv ppf env =
  Le.iter (fun p f -> fprintf ppf "@[%s@ ::@ %a@]@." (Co.path_name p) F.pprint f) (F.prune_background env); fprintf ppf "==="

let pprint_fenv_shp ppf env =
  Le.iter (fun p f -> fprintf ppf "@[%s@ ::@ %a@]@." (Co.path_name p) F.pprint (F.shape f)) (F.prune_background env); fprintf ppf "==="

let pprint_raw_fenv shp ppf env =
  Le.iter (fun p f -> fprintf ppf "@[%s@ ::@ %a@]@." (Co.path_name p) F.pprint (if shp then F.shape f else f)) env; fprintf ppf "==="

let pprint_fenv_pred so ppf env =
  Le.iter (fun x t -> pprint_local_binding F.pprint ppf (x, t)) env

let pprint_renv_pred f so ppf env =
  match so with
  | Some s -> P.pprint ppf (P.big_and (environment_preds (solution_map s) env))
  | _ -> Le.iter (fun x t -> pprint_local_binding F.pprint_refinement ppf (x, t)) env

let pprint ppf = function
  | SubFrame (e,g,f1,f2) ->
      if C.ck_olev C.ol_verb_constrs then fprintf ppf "@[(Env)@.%a@]@." pprint_fenv e;
      if C.ck_olev C.ol_verb_constrs then fprintf ppf "@[(Guard)@.%a@]@.@." P.pprint (guard_predicate g);
      fprintf ppf "@[%a@ <:@;<1 2>%a@]" F.pprint f1 F.pprint f2
  | WFFrame (e,f) ->
      if C.ck_olev C.ol_dump_wfs then begin
        if C.ck_olev C.ol_verb_constrs then fprintf ppf "@[(Env)@.%a@]@." pprint_fenv e;
        fprintf ppf "@[|- %a@]@." F.pprint f
      end

let pprint_io ppf = function
  | Some id -> fprintf ppf "(%d)" id
  | None    -> fprintf ppf "()"

let pprint_ref so ppf = function
  | SubRef (_,renv,g,r1,sr2,io) ->
      let renv = F.prune_background renv in
      fprintf ppf "@[%a@ Env:@ @[%a@];@;<1 2>Guard:@ %a@\n|-@;<1 2>%a@;<1 2><:@;<1 2>%a@]"
      pprint_io io (pprint_renv_pred F.pprint_refinement so) renv 
      P.pprint (guard_predicate g) 
      F.pprint_refinement r1 F.pprint_refinement (F.ref_of_simple sr2)
  | WFRef (env,sr,io) ->
      let env = F.prune_background env in
      C.fcprintf ppf C.ol_dump_wfs "@[%a@ Env:@ @[%a@];@\n|-@;<1 2>%a@;<1 2>@]"
      pprint_io io (pprint_fenv_pred so) env 
      F.pprint_refinement (F.ref_of_simple sr)

let pprint_orig ppf = function
  | Loc l -> fprintf ppf "Loc@ %a" Location.print l
  | Assert l -> fprintf ppf "Assert@ %a" Location.print l
  | Cstr l -> match l.lc_id with Some l -> fprintf ppf "->@ %i" l | None -> fprintf ppf "->@ ?"

(**************************************************************)
(************* Constraint Simplification & Splitting **********) 
(**************************************************************)

let refenv_of_env env =
  Le.fold begin fun x f acc -> 
      match F.get_refinement f with 
      | Some r -> Le.add x r acc
      | None   -> acc 
  end env Le.empty

  (*
let env_to_empty_refenv env =
  Le.fold (fun x f acc -> Le.add x [] acc) env Le.empty
  *)

let simplify_frame gm x f = 
  if not (Le.mem x gm) then f else
    let pos = Le.find x gm in
    match f with 
    | F.Fsum (a,b,[(subs,([(v1,v2,P.Iff (v3,p))],[]))]) when v3 = P.Boolexp (P.Var v2) ->
        let p' = if pos then p else P.Not p in
        F.Fsum (a,b,[(subs,([(v1,v2,p')],[]))])
    | _ -> f

let simplify_env env g =
  let gm = List.fold_left (fun m (x,b)  -> Le.add x b m) Le.empty g in
    Le.mapi (simplify_frame gm) env

let simplify_fc c =
  match c.lc_cstr with
  | WFFrame _ -> c 
  | SubFrame (env,g,a,b) ->
      let env' = simplify_env env g in
      {c with lc_cstr = SubFrame(env', g, a, b)}

let make_lc c fc = {lc_cstr = fc; lc_tenv = c.lc_tenv; lc_orig = Cstr c; lc_id = c.lc_id}

let lequate_cs env g c variance f1 f2 = match variance with
  | F.Invariant     -> [make_lc c (SubFrame(env,g,f1,f2)); make_lc c (SubFrame(env,g,f2,f1))]
  | F.Covariant     -> [make_lc c (SubFrame(env,g,f1,f2))]
  | F.Contravariant -> [make_lc c (SubFrame(env,g,f2,f1))]

let subst_to lfrom lto = match (lfrom, lto) with
  | (pfrom, pto) when not (Pattern.same pfrom pto) -> Pattern.substitution pfrom pto
  | _ -> []

let frame_env = function
  | SubFrame(env, _, _, _) -> env
  | WFFrame(env, _) -> env

let set_constraint_env c env = 
  let c' = match c.lc_cstr with SubFrame(_,g,f,f') -> SubFrame(env, g, f, f') | x -> x in
  {c with lc_cstr = c'}

let split_sub_ref fr c env g r1 r2 =
  let c = set_constraint_env c env in
  let v = match c.lc_cstr with SubFrame(_ , _, f, _) -> f | _ -> assert false in
  sref_map begin fun sr -> 
    let fc = FixInterface.make_t env (guard_predicate g) fr r1 sr in
    (v, c, SubRef(fc, refenv_of_env env, g, r1, sr, None))
  end r2

let params_apply_substitutions subs ps =
  List.map (fun (i, f, v) -> (i, F.apply_subs subs f, v)) ps

(* split_sub_params is a mapfold if you accumulate the subs *)
let rec split_sub_params c tenv env g ps1 ps2 = match ps1, ps2 with 
  | ((i, f, v)::ps1, (i', f', _)::ps2) ->
      let (pi, pi')    = (Co.i2p i, Co.i2p i') in
      let (env', subs) = begin match v with
        | F.Covariant | F.Invariant -> (Le.add pi f env, [(pi', P.Var pi)])
        | F.Contravariant           -> (Le.add pi' f' env, [(pi, P.Var pi')])
      end
      in lequate_cs env g c v f f' @
           split_sub_params c tenv env' g ps1 (params_apply_substitutions subs ps2)
  | ([], [])    -> []
  | _           -> assertf "split_sub_params"

let bind_tags po f cs r env =
  let is_recvar = function (Some p, F.Frec (p',_,_,_)) -> p' = p | _ -> false in
  match F.find_tag r with None -> (env, None) | Some tag -> 
    F.constrs_tag_params tag cs 
    |> List.map (fun (a,b,_) -> (Co.i2p a, if is_recvar (po, b) then f else b))
    |> FixMisc.flip Le.addn env 
    |> (fun env' -> env', Some tag)

let sum_subs = function None -> (fun _ -> []) | Some tag -> 
  (F.constrs_tag_params tag <+> F.params_ids <+> List.map Co.i2p)
  |> FixMisc.map_pair
  <+> FixMisc.uncurry (List.map2 (fun p1 p2 -> (p1, P.Var p2)))

let sum_subs = function None -> (fun _ -> []) | Some tag -> 
  (F.constrs_tag_params tag <+> F.params_ids <+> List.map Co.i2p)
  |> FixMisc.map_pair
  <+> FixMisc.uncurry (List.map2 (fun p1 p2 -> (p1, P.Var p2)))

let split_arrow env g c (x1, f1, f1') (x2, f2, f2') = 
  let f1'  = if Ident.same x1 x2 then f1' else F.apply_subs [(Co.i2p x1, P.Var (Co.i2p x2))] f1' in
  let env' = Le.add (Co.i2p x2) f2 env in
  (lequate_cs env g c F.Covariant f2 f1 @ lequate_cs env' g c F.Covariant f1' f2', [])

let split_sum f1 env tenv g c (cs1, r1) (cs2, r2) = 
  let penv, tag = bind_tags None f1 cs1 r1 env in
  let subs      = sum_subs tag (cs1, cs2) in
  let ps1, ps2  = FixMisc.map_pair (List.map F.constr_params) (cs1, cs2) in
  let cs        = FixMisc.flap2 (split_sub_params c tenv env g) ps1 ps2 in
  let rs        = List.map (F.refexpr_apply_subs subs) r2 |> split_sub_ref f1 c penv g r1 in
  cs, rs

let split_inductive env g c = 
  FixMisc.map_pair F.unfold_with_shape 
  <+> FixMisc.uncurry (lequate_cs env g c F.Covariant)
  <+> (fun x -> x, [])

let split_abstract env tenv g c (f1, f2) (id1, id2) = 
  let f2 = F.apply_subs [(Path.Pident id2, P.Var (Path.Pident id1))] f2 in
  (* an extra sub will be applied at the toplevel refinement, but OK *)
  match f1, f2 with 
  | F.Fabstract (_,ps1,id1,r1), F.Fabstract (_,ps2,_,r2) ->
    (split_sub_params c tenv (Le.add (Path.Pident id1) f1 env) g ps1 ps2, 
     split_sub_ref f1 c env g r1 r2)
  | _ -> assertf "split_abstract" 

let split_sub = function {lc_cstr = WFFrame _} -> assert false | {lc_cstr = SubFrame (env,g,f1,f2); lc_tenv = tenv} as c ->
  match (f1, f2) with
  | (_, _) when F.is_shape f1 && F.is_shape f2 ->
      ([], [])
  | (_, _) when f1 = f2 ->
      ([], [])
  | (F.Frec _, F.Frec _) ->
      ([], [])
  | (F.Farrow (x1, f1, f1'), F.Farrow (x2, f2, f2')) ->
      split_arrow env g c (x1, f1, f1') (x2, f2, f2')
  | (F.Fvar (_, _, s, r1), F.Fvar (_, _, s', r2)) ->
      ([], split_sub_ref f1 c env g r1 r2)
  | (F.Fsum (_, cs1, r1), F.Fsum (_, cs2, r2)) ->
     split_sum f1 env tenv g c (cs1, r1) (cs2, r2)
  | (F.Finductive (_, _, _, _, _), F.Finductive (_, _, _, _, _)) ->
      split_inductive env g c (f1, f2)
  | (F.Fabstract(_,_,id1,_), F.Fabstract (_,_,id2,_)) ->
      split_abstract env tenv g c (f1,f2) (id1,id2)
  | (_,_) -> 
      (printf "@[Can't@ split:@ %a@ <:@ %a@]" F.pprint f1 F.pprint f2; 
       assert false)

let split_wf_ref f c env r =
  let c = set_constraint_env c env in
  sref_map (fun sr -> (f, c, WFRef(Le.add qual_test_var f env, sr, None))) r

let make_wff c tenv env f =
  {lc_cstr = WFFrame (env, f); lc_tenv = tenv; lc_orig = Cstr c; lc_id = None}

let rec split_wf_params c tenv env ps =
  let wf_param (wfs, env) (i, f, _) =
    (make_wff c tenv env f :: wfs, Le.add (Path.Pident i) f env)
  in fst (List.fold_left wf_param ([], env) ps)

let split_wf = function {lc_cstr = SubFrame _} -> assert false | {lc_cstr = WFFrame (env,f); lc_tenv = tenv} as c ->
  match f with
  | f when F.is_shape f ->
      ([], [])
  | F.Finductive (p, ps, rr, cs, r) ->
      (make_wff c tenv env (F.wf_unfold f) :: (ps |> F.params_frames |>: make_wff c tenv env), [])
  | F.Fsum (_, cs, r) ->
     (FixMisc.flap (split_wf_params c tenv env <.> F.constr_params) cs,
      split_wf_ref f c (fst (bind_tags None f cs r env)) r)
  | F.Fabstract (_, ps, id, r) ->
      (split_wf_params c tenv (Le.add (Path.Pident id) f env) ps, split_wf_ref f c env r)
  | F.Farrow (x, f, f') ->
      ([make_wff c tenv env f; make_wff c tenv (Le.add (Co.i2p x) f env) f'], [])
  | F.Fvar (_, _, s, r) ->
      ([], split_wf_ref f c env r)
  | F.Frec _ ->
      ([], [])

let split cs =
  assert (List.for_all (fun c -> None <> c.lc_id) cs);
  FixMisc.expand begin fun c -> match c.lc_cstr with 
      | SubFrame _ -> split_sub c 
      | WFFrame _  -> split_wf c
  end cs []

(**************************************************************)
(********************* Constraint Indexing ********************) 
(**************************************************************)

module WH = 
  Heap.Functional(struct 
      type t = subref_id * int * (int * bool * fc_id)
      let compare (_,ts,(i,j,k)) (_,ts',(i',j',k')) =
        if i <> i' then compare i i' else
          if ts <> ts' then -(compare ts ts') else
            if j <> j' then compare j j' else 
              compare k' k
    end)

type ref_index = 
  { orig: labeled_constraint SIM.t;     (* id -> orig *)
    cnst: refinement_constraint SIM.t;  (* id -> refinement_constraint *) 
    rank: (int * bool * fc_id) SIM.t;   (* id -> dependency rank *)
    depm: subref_id list SIM.t;         (* id -> successor ids *)
    pend: (subref_id,unit) Hashtbl.t;   (* id -> is in wkl ? *)
  }

let get_ref_id = 
  function WFRef (_,_,Some i) | SubRef (_,_,_,_,_,Some i) -> i | _ -> assert false

let get_ref_rank sri c = 
  try SIM.find (get_ref_id c) sri.rank with Not_found ->
    (printf "ERROR: @[No@ rank@ for:@ %a@\n@]" (pprint_ref None) c; 
     raise Not_found)

let get_ref_constraint sri i = 
  FixMisc.do_catch "ERROR: get_constraint" (SIM.find i) sri.cnst

let lhs_ks = function 
  | SubRef (_,env,_,r,_,_) -> 
      Le.fold (fun _ f l -> F.refinement_qvars f @ l) env (F.refinement_qvars r)
  | _ -> assertf "lhs_ks"  

let rhs_k = function
  | SubRef (_,_,_,_,(_, F.Qvar k),_) -> Some k
  | _ -> None

let wf_k = function
  | WFRef (_, (_, F.Qvar k), _) -> Some k
  | _ -> None

let ref_k c =
  match (rhs_k c, wf_k c) with
  | (Some k, None)
  | (None, Some k) -> Some k
  | _ -> None

let ref_id = function
  | WFRef (_, _, Some id)
  | SubRef (_,_,_,_,_, Some id) -> id
  | _ -> -1

let print_scc_edge rm (u,v) = 
  let (scc_u,_,_) = SIM.find u rm in
  let (scc_v,_,_) = SIM.find v rm in
  let tag = if scc_u > scc_v then "entry" else "inner" in
  C.cprintf C.ol_refine "@[SCC@ edge@ %d@ (%s)@ %d@ ====> %d@\n@]" scc_v tag u v

let make_rank_map om cm =
  let get vm k = try IM.find k vm with Not_found -> [] in
  let upd id vm k = IM.add k (id::(get vm k)) vm in
  let km = 
    BS.time "step 1"
    (SIM.fold begin fun id c vm -> match c with 
        | SubRef _ -> List.fold_left (upd id) vm (lhs_ks c) 
        | _        -> vm 
     end cm) IM.empty in
  let (dm,deps) = 
    BS.time "step 2"
    (SIM.fold
      (fun id c (dm,deps) -> 
        match (c, rhs_k c) with 
        | (WFRef _,_) -> (dm,deps) 
        | (_,None) -> (dm,(id,id)::deps) 
        | (_,Some k) -> 
          let kds = get km k in
          let deps' = List.map (fun id' -> (id,id')) (id::kds) in
          (SIM.add id kds dm, (List.rev_append deps' deps)))
      cm) (SIM.empty,[]) in
  let flabel i = Co.io_to_string ((SIM.find i om).lc_id) in
  let rm = 
    let rank = BS.time "scc rank" (Co.scc_rank flabel) deps in
    BS.time "step 2"
    (List.fold_left
      (fun rm (id,r) -> 
        let b = (not !Cf.psimple) || (is_simple_constraint (SIM.find id cm)) in
        let fci = (SIM.find id om).lc_id in
        SIM.add id (r,b,fci) rm)
      SIM.empty) rank in
  (dm,rm)

let fresh_refc = 
  let i = ref 0 in
  fun c -> 
    let i' = incr i; !i in
    match c with  
    | WFRef (env,r,None) -> WFRef (env,r,Some i')
    | SubRef (x,env,g,r1,r2,None) -> SubRef (x,env,g,r1,r2,Some i')
    | _ -> assert false

(* API *)
let make_ref_index ocs = 
  let (om,cm) =
    ocs |> List.map (fun (_, o, c) -> (o, fresh_refc c))
        |> List.fold_left begin fun (om, cm) (o, c) -> 
            let i = get_ref_id c in 
            (SIM.add i o om, SIM.add i c cm)
           end (SIM.empty, SIM.empty) 
  in let (dm,rm) = BS.time "make rank map" (make_rank_map om) cm in
  {orig = om; cnst = cm; rank = rm; depm = dm; pend = Hashtbl.create 17}

let get_ref_orig sri c = 
  FixMisc.do_catch "ERROR: get_ref_orig" (SIM.find (get_ref_id c)) sri.orig

let get_ref_fenv orig c =
  (function SubFrame (a, _, _, _) | WFFrame (a, _) -> a) orig.lc_cstr

(* API *)
let get_ref_deps sri c =
  let is' = try SIM.find (get_ref_id c) sri.depm with Not_found -> [] in
  List.map (get_ref_constraint sri) is'

(* API *)
let get_ref_constraints sri = 
  SIM.fold (fun _ c cs -> c::cs) sri.cnst [] 

(* API *)
let iter_ref_constraints sri f = 
  SIM.iter (fun _ c -> f c) sri.cnst

let iter_ref_origs sri f =
  SIM.iter (fun i c -> f i c) sri.orig

let sort_iter_ref_constraints sri f = 
  let rids  = SIM.fold (fun id (r,_,_) ac -> (id,r)::ac) sri.rank [] in
  let rids' = List.sort (fun x y -> compare (snd x) (snd y)) rids in 
  List.iter (fun (id,_) -> f (SIM.find id sri.cnst)) rids' 


(* API *)
let push_worklist =
  let timestamp = ref 0 in
  fun sri w cs ->
    incr timestamp;
    List.fold_left begin fun w c -> 
      let id = get_ref_id c in
      if Hashtbl.mem sri.pend id then w else begin 
        C.cprintf C.ol_refine "@[Pushing@ %d at %d@\n@]" id !timestamp; 
        Hashtbl.replace sri.pend id (); 
        WH.add (id,!timestamp,get_ref_rank sri c) w
      end
    end w cs

(* API *)
let pop_worklist sri w =
  try 
    let (id, _, _) = WH.maximum w in
    let _ = Hashtbl.remove sri.pend id in
    (Some (get_ref_constraint sri id), WH.remove w)
  with Heap.EmptyHeap -> (None,w) 

(* API *)
let make_initial_worklist sri =
  let cs = List.filter is_subref_constraint (get_ref_constraints sri) in
  push_worklist sri WH.empty cs 

(**************************************************************)
(************************** Refinement ************************)
(**************************************************************)

module PM = Map.Make(struct type t = P.t let compare = compare end)

let close_over_env env s ps =
  let rec close_rec clo = function
      | [] -> clo
      | ((P.Atom (P.Var x, P.Eq, P.Var y)) as p)::ps ->
          let tvar =
            if Path.same x qual_test_var then Some y else 
              if Path.same y qual_test_var then Some x else None in
          (match tvar with None -> close_rec (p :: clo) ps | Some t ->
            let ps' = F.conjuncts s qual_test_expr (Le.find t env) in
            close_rec (p :: clo) (ps'@ps))
      | p::ps -> close_rec (p :: clo) ps in
  close_rec [] ps 

let refine_sol_update s k qs qs' = 
  BS.time "sol replace" (Sol.replace s k) qs';
  not (FixMisc.same_length qs qs')

let refine_simple s r1 k2 =
  let k1s  = FixMisc.flap (fun (_,(_,ks)) -> ks) r1 in
  let q1s  = FixMisc.flap (Sol.find s) k1s in
  let q1s  = List.fold_left (fun qs q -> QSet.add q qs) QSet.empty q1s in
  let q2s  = Sol.find s k2 in
  let q2s' = List.filter (fun q -> QSet.mem q q1s) q2s in
  refine_sol_update s k2 q2s q2s'


let qual_wf sm env subs q =
  BS.time "qual_wf" 
  (refinement_well_formed env sm (F.mk_refinement subs [q] [])) qual_test_expr

let lhs_preds sm env g r1 =
  let gp    = guard_predicate g in
  let envps = environment_preds sm env in
  let r1ps  = refinement_preds  sm qual_test_expr r1 in
  envps @ (gp :: r1ps) 

let rhs_cands sm subs k = 
  List.map 
    (fun q -> 
      let r = F.mk_refinement subs [q] [] in
      (q,F.refinement_predicate sm qual_test_expr r))
    (sm k) 

let check_tp senv lhs_ps x2 = 
  let dump s p = 
    let p = List.map (fun p -> P.big_and (List.filter (function P.Atom(p, P.Eq, p') when p = p' -> false | _ -> true) (P.conjuncts p))) p in
    let p = List.filter (function P.True -> false | _ -> true) p in
    C.cprintf C.ol_dump_prover "@[%s:@ %a@]@." s (FixMisc.pprint_many false " " P.pprint) p in
  let dump s p = if C.ck_olev C.ol_dump_prover then dump s p else () in
  let _ = dump "Assert" lhs_ps in
  let _ = if C.ck_olev C.ol_dump_prover then dump "Ck" (snd (List.split x2)) in
  let rv = 
    try
      TP.set_and_filter senv lhs_ps x2
    with Failure x -> printf "%a@." pprint_fenv senv; raise (Failure x) in
  let _ = if C.ck_olev C.ol_dump_prover then dump "OK" (snd (List.split rv)) in
  incr stat_tp_refines;
  stat_imp_queries   := !stat_imp_queries + (List.length x2);
  stat_valid_queries := !stat_valid_queries + (List.length rv); rv

let check_tp senv lhs_ps x2 =
  match x2 with 
  | [] -> (incr stat_tp_refines; []) 
  | _  -> BS.time "check_tp" (check_tp senv lhs_ps) x2 

let bound_in_env senv p =
  List.for_all (fun x -> Le.mem x senv) (P.vars p)

let refine_tp senv s env g r1 sub2s k2 =
  let sm = solution_map s in
  let lhs_ps  = lhs_preds sm env g r1 in
  let rhs_qps = rhs_cands sm sub2s k2 in
  let rhs_qps' =
    if List.exists P.is_contra lhs_ps 
    then (stat_matches := !stat_matches + (List.length rhs_qps); rhs_qps) 
    else
      let rhs_qps = List.filter (fun (_,p) -> not (P.is_contra p)) rhs_qps in
      let lhsm    = List.fold_left (fun pm p -> PM.add p true pm) PM.empty lhs_ps in
      let (x1,x2) = List.partition (fun (_,p) -> PM.mem p lhsm) rhs_qps in
      let _       = stat_matches := !stat_matches + (List.length x1) in 
      match x2 with [] -> x1 | _ -> x1 @ (check_tp senv lhs_ps x2) in
  refine_sol_update s k2 rhs_qps (List.map fst rhs_qps') 

let refine_sub s orig c = 
  let _  = incr stat_refines; incr stat_sub_refines in
  match c with
  | SubRef (_,_, _, r1, ([], F.Qvar k2), _)
    when is_simple_constraint c && not (!Cf.no_simple || !Cf.verify_simple) ->
      incr stat_simple_refines; 
      refine_simple s r1 k2
  | SubRef (_,_, _, _, (_, F.Qvar k2), _) when (solution_map s k2) = [] ->
      false
  | SubRef (_,env,g,r1, (sub2s, F.Qvar k2), _)  ->
      refine_tp (get_ref_fenv orig c) s env g r1 sub2s k2 
  | _ -> 
      false

let refine_wf s = function 
  | WFRef (env, (subs, F.Qvar k), _) ->
      let _   = incr stat_refines; incr stat_wf_refines in
      let qs  = solution_map s k in
      let _   = if C.ck_olev C.ol_dump_wfs then printf "@.@.@[WF: k%d@]@." k in
      let _   = if C.ck_olev C.ol_dump_wfs then printf "@[(Env)@ %a@]@." pprint_fenv_shp env in 
      let qs' = BS.time "filter wf" (List.filter (qual_wf (solution_map s) env subs)) qs in
      let _   = if C.ck_olev C.ol_dump_wfs then List.iter (fun q -> printf "%a" Lqualifier.pprint q) qs in
      let _   = if C.ck_olev C.ol_dump_wfs then printf "@.@." in
      let _   = if C.ck_olev C.ol_dump_wfs then List.iter (fun q -> printf "%a" Lqualifier.pprint q) qs' in
      refine_sol_update s k qs qs'
  | _ -> false 
 
  (*let _ = printf "(sub) ERROR: refine_wf on @[%a@.@]" (pprint_ref None) c in
      let _ = printf "(sub) ERROR: refine_wf on @[%a@.@]" (pprint_ref None) c in
*)

(**************************************************************)
(********************** Constraint Satisfaction ***************)
(**************************************************************)

let sat s orig = function 
  | SubRef (_,env,g,r1, (sub2s, F.Qvar k2), _)  ->
      true
  | SubRef (_,env, g, r1, sr2, _) as c ->
      let sm     = solution_map s in
      let lhs_ps = lhs_preds sm env g r1 in
      let rhs    = F.refinement_predicate sm qual_test_expr (F.ref_of_simple sr2) in
      (1 = List.length (check_tp (get_ref_fenv orig c) lhs_ps [(0,rhs)]))
  | WFRef (env,(subs, F.Qvar k), _) ->
      true 
  | _ -> true

let unsat_constraints cs s =
  FixMisc.map_partial (fun (_,o, c) -> if sat s o c then None else Some (c, o)) cs

(**************************************************************)
(******************** Qualifier Instantiation *****************)
(**************************************************************)

module TR = Trie.Make(Map.Make(Co.ComparablePath))

let mk_envl env = Le.fold (fun p f l -> if Path.same p qual_test_var || Co.path_is_temp p then l else p :: l) env []

let tr_misses = ref 0

let instantiate_quals_in_env tr mlenv consts qs =
    (fun (env, envl') ->
        let (vs, (env, envl, quoi)) = TR.find_maximal envl' tr (fun (_, _, quoi) -> FixMisc.maybe_bool !quoi) in
        match !quoi with
          | Some qs -> 
            quoi := Some qs;
            List.iter (fun (_, _, q) -> if FixMisc.maybe_bool !q then () else q := Some qs) vs; qs
          | None -> 
            let _   = incr tr_misses in
            let qs = FixMisc.fast_flap
            (fun q -> try Qualdecl.expand_qualpat_about consts env mlenv q with Failure _ -> []) qs in
            let _ = TR.iter_path envl tr 
              (fun (_, _, quoi) ->
                match !quoi with
                | Some q -> if (List.length q) > (List.length qs)
                            then quoi := Some qs
                | None -> ()) in
            quoi := Some qs; qs)

(* Make copies of all the qualifiers where the free identifiers are replaced
   by the appropriate bound identifiers from all environments. *)
let instantiate_per_environment mlenv consts cs qs =
  let envs = List.rev_map (function _,_,WFRef (e,_,_) -> e | _,_,_ -> Le.empty) cs in
  let envls = List.map mk_envl envs in 
  let envvs = List.combine envs envls in
  let tr = List.fold_left (fun t (ev, el) -> TR.add el (ev, el, ref None) t) TR.empty envvs in
  BS.time "instquals" (List.rev_map (instantiate_quals_in_env tr mlenv consts qs)) envvs

let filter_quals qss =
  let valid q =
    Lqualifier.may_not_be_tautology q &&
    Lqualifier.no_div_by_zero q in
  List.map (fun qs -> List.filter valid qs) qss


(**************************************************************)
(************************ Initial Solution ********************)
(**************************************************************)

(* If a variable only ever appears on the left hand side, the variable is
 * unconstrained; this generally indicates an uncalled function.
 * When we have such an unconstrained variable, we simply say we don't
 * know anything about its value.  For uncalled functions, this will give
 * us the type which makes the least assumptions about the input. *)

let formals = ref []
let is_formal q = List.mem q !formals
let formals_addn qs = formals := qs ++ !formals

let filter_wfs cs = List.filter (fun (r, _) -> match r with WFRef(_, _, _) -> true | _ -> false) cs
let filter_subs cs = List.filter (fun (r, _) -> match r with SubRef(_,_, _, _, _, _) -> true | _ -> false) cs
type solmode = WFS | LHS | RHS

let app_sol s s' l k qs = 
  let f qs q = QSet.add q qs in
  if Sol.mem s k then
    if Sol.mem s' k then
      Sol.replace s' k (List.fold_left f (Sol.find s' k) qs)
    else Sol.replace s k qs

let make_initial_solution cs =
  let srhs = Hashtbl.create 100 in
  let slhs = Hashtbl.create 100 in
  let s = Sol.create 100 in
  let s' = Sol.create 100 in
  let l = ref [] in
  let _ = List.iter begin function 
          | SubRef (_,_, _, _, (_, F.Qvar k), _), qs ->
              Hashtbl.replace srhs k (); Sol.replace s k qs
          | _ -> () end cs in
  let _ = List.iter begin function 
          | SubRef (_,_, _, r1, _, _), qs ->
              List.iter (fun k -> Hashtbl.replace slhs k ();
                                  if not !Cf.minsol && is_formal k && not (Hashtbl.mem srhs k) 
                                  then Sol.replace s k [] 
                                  else Sol.replace s k qs) (F.refinement_qvars r1) 
          | _ -> ()
          end cs in
  let _ = List.iter begin function 
          | WFRef (_, (_, F.Qvar k), _), qs ->
              if Hashtbl.mem srhs k || (Hashtbl.mem slhs k && Sol.find s k != []) then 
                BS.time "app_sol" (app_sol s s' l) k qs 
              else Sol.replace s k [] 
          | _ -> ()
          end cs in
  let l = BS.time "sort and compact" FixMisc.sort_and_compact !l in
  let _ = BS.time "elements" (List.iter (fun k -> Sol.replace s k (QSet.elements (Sol.find s' k)))) l in
  s

(**************************************************************)
(****************** Debug/Profile Information *****************)
(**************************************************************)
 
let dump_ref_constraints sri =
  if !Cf.dump_ref_constraints then begin
    printf "@[Refinement Constraints@.@\n@]";
    iter_ref_constraints sri (fun c -> printf "@[%a@.@]" (pprint_ref None) c);
    printf "@[SCC Ranked Refinement Constraints@.@\n@]";
    sort_iter_ref_constraints sri (fun c -> printf "@[%a@.@]" (pprint_ref None) c);
  end

let dump_ref_vars sri =
  if !Cf.dump_ref_vars then
  (printf "@[Refinement Constraint Vars@.@\n@]";
  iter_ref_constraints sri (fun c -> printf "@[(%d)@ %s@.@]" (ref_id c) 
    (match (ref_k c) with Some k -> string_of_int k | None -> "None")))
   
let dump_constraints cs =
  if !Cf.dump_constraints then begin
    printf "******************Frame Constraints****************@.@.";
    let index = ref 0 in
    List.iter (fun {lc_cstr = c; lc_orig = d} -> if (not (is_wfframe_constraint c)) || C.ck_olev C.ol_dump_wfs then 
            (incr index; printf "@[(%d)(%a) %a@]@.@." !index pprint_orig d pprint c)) cs;
    printf "@[*************************************************@]@.@.";
  end

let dump_solution_stats s = 
  if C.ck_olev C.ol_solve_stats then
    let kn  = Sol.length s in
    let (sum, max, min) =   
      (Sol.fold (fun _ qs x -> (+) x (List.length qs)) s 0,
      Sol.fold (fun _ qs x -> max x (List.length qs)) s min_int,
      Sol.fold (fun _ qs x -> min x (List.length qs)) s max_int) in
    C.cprintf C.ol_solve_stats "@[Quals:@\n\tTotal:@ %d@\n\tAvg:@ %f@\n\tMax:@ %d@\n\tMin:@ %d@\n@\n@]"
    sum ((float_of_int sum) /. (float_of_int kn)) max min;
    print_flush ()
  else ()
  
let dump_unsplit cs =
  let cs = if C.ck_olev C.ol_solve_stats then List.rev_map (fun c -> c.lc_cstr) cs else [] in
  let cc f = List.length (List.filter f cs) in
  let (wf, sub) = (cc is_wfframe_constraint, cc is_subframe_constraint) in
  C.cprintf C.ol_solve_stats "@.@[unsplit@ constraints:@ %d@ total@ %d@ wf@ %d@ sub@]@.@." (List.length cs) wf sub

let dump_solving step (cs, s) =
  let cs = List.map thd3 cs in
  if step = 0 then 
    let kn   = Sol.length s in
    let wcn  = List.length (List.filter is_wfref_constraint cs) in
    let rcn  = List.length (List.filter is_subref_constraint cs) in
    let scn  = List.length (List.filter is_simple_constraint cs) in
    let scn2 = List.length (List.filter is_simple_constraint2 cs) in
    (C.cprintf C.ol_solve_stats "@[%d@ variables@\n@\n@]" kn;
     C.cprintf C.ol_solve_stats "@[%d@ split@ wf@ constraints@\n@\n@]" wcn;
     C.cprintf C.ol_solve_stats "@[%d@ split@ subtyping@ constraints@\n@\n@]" rcn;
     C.cprintf C.ol_solve_stats "@[%d@ simple@ subtyping@ constraints@\n@\n@]" scn;
     C.cprintf C.ol_solve_stats "@[%d@ simple2@ subtyping@ constraints@\n@\n@]" scn2;
     dump_solution_stats s) 
  else if step = 1 then
    dump_solution_stats s
  else if step = 2 then
    (C.cprintf C.ol_solve_stats 
      "@[Refine Iterations: %d@ total (= wf=%d + su=%d) sub includes si=%d tp=%d unsatLHS=%d)\n@\n@]"
      !stat_refines !stat_wf_refines  !stat_sub_refines !stat_simple_refines !stat_tp_refines !stat_unsat_lhs;
     C.cprintf C.ol_solve_stats "@[Implication Queries:@ %d@ match;@ %d@ to@ TP@ (%d@ valid)@]@.@." 
       !stat_matches !stat_imp_queries !stat_valid_queries;
     if C.ck_olev C.ol_solve_stats then TP.print_stats std_formatter () else ();
     dump_solution_stats s;
     flush stdout)

let dump_qualifiers qs =
  if C.ck_olev C.ol_insane then begin 
    printf "Raw generated qualifiers:@.";
    List.iter (printf "%a@.@." (FixMisc.pprint_many false "," Lqualifier.pprint)) qs;
    printf "done.@."
  end

(**************************************************************)
(******************** Iterative - Refinement  *****************)
(**************************************************************)

let rec solve_sub s (sri, w) = 
  (if !stat_refines mod 100 = 0 then C.cprintf C.ol_solve "@[num@ refines@ =@ %d@\n@]" !stat_refines);
  match pop_worklist sri w with (None,_) -> s | (Some c, w') ->
    let (r,b,fci) = get_ref_rank sri c in
    let _ = C.cprintf C.ol_refine "@.@[Refining@ %d@ at iter@ %d in@ scc@ (%d,%b,%s):@]@."
            (get_ref_id c) !stat_refines r b (Co.io_to_string fci) in
    let _ = if C.ck_olev C.ol_insane then S.dump "solve_sub" s in
    let o = get_ref_orig sri c in 
    let w' = if BS.time "refine" (refine_sub s o) c 
             then push_worklist sri w' (get_ref_deps sri c) else w' in
    solve_sub s (sri, w')

let solve_wf s cs =
  cs |> FixMisc.map thd3
     |> FixMisc.filter (function WFRef _ -> true | _ -> false) 
     |> FixMisc.iter (refine_wf s <+> ignore)

let print_unsats = function
  | [] -> ()
  | cs -> C.cprintf C.ol_solve_error "Unsatisfied Constraints\n%a" (FixMisc.pprint_many true "\n" (pprint_ref None)) cs

let test_sol (cs, s) =
  s >> S.dump "test_sol" 
    |> BS.time "testing solution" (unsat_constraints cs)
    >> (fun xs -> try xs |> List.map fst |> print_unsats with _ -> ()) 
    |> List.map snd
    |> (fun xs -> (solution_map s, xs))

let dsolver cs s =
  cs |> make_ref_index 
     >> dump_ref_vars
     >> dump_ref_constraints
     |> FixMisc.pad_snd make_initial_worklist
     |> BS.time "solving sub" (solve_sub s)
     >> (fun _ -> TP.reset ())

let pprint_tb = fun ppf (f, io) -> Format.fprintf ppf "@[%a in %a@]" F.pprint f FixMisc.pprint_int_o io

let checkenv_of_cs cs = 
  List.fold_left begin fun env (v, c, _) -> 
    Le.fold begin fun k v env ->
      let vs = try Le.find k env with _ -> [] in
      Le.add k ((v,c.lc_id)::vs) env
    end (frame_env c.lc_cstr) env
  end Le.empty cs
  |> Le.iter begin fun k vs -> match vs with [] -> () | (v,_)::_ ->
       if not (List.for_all (fst <+> F.same_shape v) vs) then begin
         Format.printf "DUPLICATE BINDINGS for %s \n%a" 
         (Path.unique_name k) (FixMisc.pprint_many true "\n" pprint_tb) vs;
         assertf "ERROR: FUPLICATE BINDING"
       end
  end

let env_of_cs cs =
  cs >> (if !Cf.check_dupenv then checkenv_of_cs else ignore)
     |> List.fold_left (fun env (v, c, _) -> Le.combine (frame_env c.lc_cstr) env) Le.empty

let solve_wfs env consts qs cs =
  let max_env = env_of_cs cs in
  let _ = C.cprintf C.ol_insane "===@.Maximum@ Environment@.@.%a@.@." (pprint_raw_fenv true) max_env in
  let cs = List.map (fun (fr, c, cstr) -> (fr, set_constraint_env c (Le.add qual_test_var fr max_env), cstr)) cs in
  let qs = BS.time "instantiating quals" (instantiate_per_environment env consts cs) qs in
  let qs = BS.time "filter quals" filter_quals qs in
  let _ = if C.ck_olev C.ol_solve then
          C.cprintf C.ol_solve "@[%i@ instantiation@ queries@ %i@ misses@]@." (List.length cs) !tr_misses in
  let _ = if C.ck_olev C.ol_solve then
          C.cprintf C.ol_solve_stats "@[%i@ qualifiers@ generated@]@." (List.length (List.flatten qs)) in
  let _ = if C.ck_olev C.ol_insane then dump_qualifiers qs in
  let s = BS.time "make initial sol" make_initial_solution (List.combine (List.map thd3 cs) qs) in
  let _ = dump_solving 0 (cs, s) in
  let _ = S.dump "initial sol" s in
  let _ = BS.time "solving wfs" (solve_wf s) cs in
  let _ = C.cprintf C.ol_solve "@[AFTER@ WF@]@." in
  let _ = dump_solving 1 (cs, s) in
  let _ = S.dump "after WF" s in
    (cs, s)

let solve_subs sourcefile (cs, s) =
  (cs, if !Clflags.use_fixpoint then FixInterface.solver sourcefile cs s else dsolver cs s)

let solve sourcefile after_wf env consts qs cs =
     (if !Cf.simpguard then List.map simplify_fc cs else cs)
  >> dump_constraints
  >> dump_unsplit
  |> BS.time "splitting constraints" split
  |> solve_wfs env consts qs
  >> FixMisc.iter_snd after_wf
  |> solve_subs sourcefile
  >> dump_solving 2
  |> test_sol
