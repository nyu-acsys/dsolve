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
 *)

(* This file is part of the LiquidC Project *)

module Co = Constants
module BS = BNstats
module A  = Ast
module Sy = A.Symbol
module So = A.Sort
module SM = Sy.SMap
module SSM = FixMisc.StringMap
module P  = A.Predicate
module E  = A.Expression
open FixMisc.Ops

module Prover : ProverArch.PROVER = struct

let mydebug = false 

(********************************************************************************)
(********************************** Type Definitions ****************************)
(********************************************************************************)

type decl = Vbl of (Sy.t * So.t) | Fun of Sy.t * int | Barrier

type var_ast = Const of Z3.ast | Bound of int * So.t

type t = { 
  c             : Z3.context;
  tint          : Z3.sort;
  tbool         : Z3.sort;
  vart          : (decl, var_ast) Hashtbl.t;
  funt          : (decl, Z3.func_decl) Hashtbl.t;
  tydt          : (So.t, Z3.sort) Hashtbl.t;
  mutable vars  : decl list ;
  mutable count : int;
  mutable bnd   : int;
}

(*************************************************************************)
(************************** Pretty Printing ******************************)
(*************************************************************************)

let pprint_decl ppf = function
  | Vbl (x, t) 	-> Format.fprintf ppf "%a:%a" Sy.print x So.print t 
  | Barrier 	-> Format.fprintf ppf "----@." 
  | Fun (s, i) 	-> Format.fprintf ppf "%a[%i]" Sy.print s i

let dump_ast_type me a = 
  Z3.get_sort me.c a  
  |> Z3.sort_to_string me.c  
  |> Format.printf "@[z3%s@]@."

let dump_ast me a =
  Z3.ast_to_string me.c a
  |> Format.printf "@[%s@]@." 

let dump_decls me =
  Format.printf "Vars: %a" (FixMisc.pprint_many true "," pprint_decl) me.vars       

(************************************************************************)
(***************************** Stats Counters  **************************)
(************************************************************************)

let nb_set  		= ref 0
let nb_push 		= ref 0
let nb_pop  		= ref 0
let nb_unsat		= ref 0
let nb_query 		= ref 0
let nb_unsatLHS         = ref 0

(************************************************************************)
(********************** Misc. Constants *********************************)
(************************************************************************)

(* let bofi_n = Sy.of_string "_BOFI" *)
(* let iofb_n = Sy.of_string "_IOFB" *)
let div_n  = Sy.of_string "_DIV"
let tag_n  = Sy.of_string "_TAG"

let axioms = []
(* THESE CAUSE Z3 to SEG-FAULT (tests/t6.fq), 
 * most likely an error in the forall-translation
  let x = Sy.of_string "x" in
  [A.pForall ([(x, So.Bool)],                            
               A.pIff ((A.pAtom (A.eApp (iofb_n, [A.eVar x]), A.Eq, A.one)),
                       (A.pBexp (A.eVar x))));
   A.pForall ([(x, So.Int)],
               A.pIff (A.pBexp (A.eApp (bofi_n, [A.eVar x])),
                       A.pAtom (A.eVar x, A.Eq, A.one)))]
 *)

(* TBD these are related to ML and should be in DSOLVE, not here *)
let builtins = 
  SM.empty 
  |> SM.add tag_n  (So.t_func 0 [So.t_obj; So.t_int])
  |> SM.add div_n  (So.t_func 0 [So.t_int; So.t_int; So.t_int]) 
(*|> SM.add iofb_n (So.Func (0, [So.Bool; So.Int])) *)
(*|> SM.add bofi_n (So.Func (0, [So.Int; So.Bool])) *)

let select_t = So.t_func 0 [So.t_int; So.t_int]

let mk_select, is_select =
  let ss = "SELECT" in
  (fun f -> Sy.to_string f |> (^) (ss ^ "_") |> Sy.of_string),
  (fun s -> Sy.to_string s |> FixMisc.is_prefix ss)

let fresh = 
  let x = ref 0 in
  fun v -> incr x; (v^(string_of_int !x))

(*************************************************************************)
(********************** Typing *******************************************)
(*************************************************************************)

let varSort env s =
  try SM.find s env with Not_found -> 
    failure "ERROR: varSort cannot type %s in TPZ3 \n" (Sy.to_string s) 

let funSort env s =
  try SM.find s builtins with Not_found -> 
    try SM.find s env with Not_found -> 
      if is_select s then select_t else 
        failure "ERROR: could not type function %s in TPZ3 \n" (Sy.to_string s) 

let z3VarType me t =
  FixMisc.do_memo me.tydt begin fun t -> 
    if So.is_bool t 
    then me.tbool 
    else me.tint
  end t t
    
(***********************************************************************)
(********************** Identifiers ************************************)
(***********************************************************************)

let z3Vbl env x = Vbl (x, varSort env x)

let z3Var_memo me env x =
  let vx  = z3Vbl env x in
  FixMisc.do_memo me.vart
    (fun () -> 
      let t   = x |> varSort env |> z3VarType me in
      let sym = fresh "z3v" 
                (* >> Format.printf "z3Var_memo: %a :->  %s\n" Sy.print x *)
                |> Z3.mk_string_symbol me.c in 
      let rv  = Const (Z3.mk_const me.c sym t) in
      let _   = me.vars <- vx :: me.vars in 
      rv) 
    () vx

let z3Var me env x =
  match BS.time "z3Var memo" (z3Var_memo me env) x with
  | Const v     -> v
  | Bound (b,t) -> Z3.mk_bound me.c (me.bnd - b) (z3VarType me t)

let z3Bind me env x t =
  let vx = Vbl (x, varSort env x) in
  me.bnd <- me.bnd + 1; 
  Hashtbl.replace me.vart vx (Bound (me.bnd, t)); 
  me.vars <- vx :: me.vars;
  Z3.mk_string_symbol me.c (fresh "z3b")

let z3Fun me env p t k = 
  FixMisc.do_memo me.funt begin fun _ -> 
    match So.func_of_t t with
    | None          -> assertf "MATCH ERROR: z3ArgTypes" 
    | Some (ts, rt) ->
        let ts = List.map (z3VarType me) ts in
        let rt = z3VarType me rt in
        let cf = Z3.mk_string_symbol me.c (fresh "z3f") in
        let rv = Z3.mk_func_decl me.c cf (Array.of_list ts) rt in
        let _  = me.vars <- (Fun (p,k))::me.vars in
        rv
  end () (Fun (p, k))

(**********************************************************************)
(********************** Pred/Expr Transl ******************************)
(**********************************************************************)

let is_z3_bool me a =
  a |> Z3.get_sort me.c   
    |> Z3.sort_to_string me.c
    |> (=) "bool"
 
let is_z3_int me a =
  a |> Z3.get_sort me.c   
    |> Z3.sort_to_string me.c
    |> (=) "int"

exception Z3RelTypeError

let rec z3Rel me env (e1, r, e2) =
  if A.sortcheck_pred (FixMisc.flip SM.maybe_find env) (A.pAtom (e1, r, e2)) then 
    let a1, a2 = FixMisc.map_pair (z3Exp me env) (e1, e2) in 
    match r with 
    | A.Eq -> Z3.mk_eq me.c a1 a2 
    | A.Ne -> Z3.mk_distinct me.c [|a1; a2|]
    | A.Gt -> Z3.mk_gt me.c a1 a2
    | A.Ge -> Z3.mk_ge me.c a1 a2
    | A.Lt -> Z3.mk_lt me.c a1 a2
    | A.Le -> Z3.mk_le me.c a1 a2
  else begin 
    SM.iter (fun s t -> Format.printf "@[%a :: %a@]@." Sy.print s So.print t) env;
    Format.printf "@[%a@]@.@." P.print (A.pAtom (e1, r, e2));
    Format.print_flush ();
    raise Z3RelTypeError
  end

and z3App me env p zes =
  let t  = funSort env p in
  let cf = z3Fun me env p t (List.length zes) in
  Z3.mk_app me.c cf (Array.of_list zes)

and z3Exp me env = function
  | A.Con (A.Constant.Int i), _ -> 
      Z3.mk_int me.c i me.tint 
  | A.Var s, _ -> 
      z3Var me env s
  | A.App (f, es), _ -> 
      z3App me env f (List.map (z3Exp me env) es)
  | A.Bin (e1, A.Plus, e2), _ ->
      Z3.mk_add me.c (Array.map (z3Exp me env) [|e1; e2|])
  | A.Bin (e1, A.Minus, e2), _ ->
      Z3.mk_sub me.c (Array.map (z3Exp me env) [|e1; e2|])
  | A.Bin((A.Con (A.Constant.Int n1), _), A.Times, (A.Con (A.Constant.Int n2), _)),_ ->
      Z3.mk_int me.c (n1 * n2) me.tint
  | A.Bin (e1, A.Times, e2), _ ->
      Z3.mk_mul me.c (Array.map (z3Exp me env) [|e1; e2|])
  | A.Bin (e1, A.Div, e2), _ -> 
      z3App me env div_n (List.map (z3Exp me env) [e1;e2])
  | A.Bin (e, A.Mod, (A.Con (A.Constant.Int i), _)), _ ->
      Z3.mk_mod me.c (z3Exp me env e) (Z3.mk_int me.c i me.tint)
  | A.Bin (e1, A.Mod, e2), _ ->
      Z3.mk_mod me.c (z3Exp me env e1) (z3Exp me env e2)
  | A.Ite (e1, e2, e3), _ -> 
      Z3.mk_ite me.c (z3Pred me env e1) (z3Exp me env e2) (z3Exp me env e3)
  | A.Fld (f, e), _ -> 
      z3App me env (mk_select f) [z3Exp me env e] (** REQUIRES: disjoint field names *)
  | A.Cst (e, _), _ -> 
      z3Exp me env e
  | e -> 
      assertf "z3Exp: Cannot Convert %s!" (E.to_string e) 

and z3Pred me env = function
  | A.True, _ -> 
      Z3.mk_true me.c
  | A.False, _ ->
      Z3.mk_false me.c
  | A.Not p, _ -> 
      Z3.mk_not me.c (z3Pred me env p)
  | A.And ps, _ -> 
      Z3.mk_and me.c (Array.of_list (List.map (z3Pred me env) ps))
  | A.Or ps, _  -> 
      Z3.mk_or me.c (Array.of_list (List.map (z3Pred me env) ps))
  | A.Imp (p1, p2), _ -> 
      Z3.mk_implies me.c (z3Pred me env p1) (z3Pred me env p2)
  | A.Iff (p1, p2), _ ->
      Z3.mk_iff me.c (z3Pred me env p1) (z3Pred me env p2)
  | A.Atom (e1, r, e2), _ ->
      z3Rel me env (e1, r, e2)
  | A.Bexp e, _ -> 
      let a  = z3Exp me env e in
      let s1 = Z3.ast_to_string me.c a in
      let s2 = E.to_string e in
      let Some so = A.sortcheck_expr (FixMisc.flip SM.maybe_find env) e in
      let sos = So.to_string so in
      let _  = asserts (is_z3_bool me a) "Bexp is not bool (e = %s)! z3=%s, fix=%s, sort=%s" 
                                         (E.to_string e) s1 s2 sos in 
      a
 | A.Forall (xts, p), _ -> 
      let (xs, ts) = List.split xts in
      let zargs    = Array.of_list (List.map2 (z3Bind me env) xs ts) in
      let zts      = Array.of_list (List.map  (z3VarType me) ts) in 
      let rv       = Z3.mk_forall me.c 0 [||] zts zargs (z3Pred me env p) in
      let _        = me.bnd <- me.bnd - (List.length xs) in
      rv
 | p -> 
      assertf "z3Pred: Cannot Convert %s!" (P.to_string p) 


let z3Pred me env p = 
  try 
    let p = BS.time "fixdiv" A.fixdiv p in
    BS.time "z3Pred" (z3Pred me env) p
  with ex -> (Format.printf "z3Pred: error converting %a\n" P.print p) ; raise ex 


let z3Distinct me env = 
  List.map (z3Var me env) <+> Array.of_list <+> Z3.mk_distinct me.c

(***************************************************************************)
(***************** Low Level Query Interface *******************************)
(***************************************************************************)

let us_ref = ref 0

let unsat me =
  let _  = if mydebug then (Printf.printf "[%d] UNSAT 1 " (us_ref += 1); flush stdout) in
  let rv = (BS.time "Z3.check" Z3.check me.c) = Z3.L_FALSE in
  let _  = if mydebug then (Printf.printf "UNSAT 2 \n"; flush stdout) in
  let _  = if rv then ignore (nb_unsat += 1) in 
  rv

let assert_axiom me p =
  (* Co.bprintf mydebug "@[Pushing axiom %s@]@." (Z3.ast_to_string me.c p); *)
  BS.time "Z3 assert axiom" (Z3.assert_cnstr me.c) p;
  asserts (not(unsat me)) "ERROR: Axiom makes background theory inconsistent!"

let rec vpop (cs,s) =
  match s with 
  | [] -> (cs,s)
  | Barrier :: t -> (cs,t)
  | h :: t -> vpop (h::cs,t) 

let prep_preds me env ps =
  let ps = List.rev_map (z3Pred me env) ps in
  let _  = me.vars <- Barrier :: me.vars in
  ps

let z3push me =
  let _ = nb_push += 1 in
  let _ = me.count <- me.count + 1 in
  let _ = BS.time "Z3.push" Z3.push me.c in
  () (* List.iter (fun p -> BS.time "Z3.ass_cst" (Z3.assert_cnstr me.c) p) ps *)

let z3pop me =
  let _ = incr nb_pop in
  let _ = me.count <- me.count - 1 in
  BS.time "Z3.pop" (Z3.pop me.c) 1 

(* Z3 API *)
let z3Do me f      = FixMisc.bracket (fun _ -> z3push me) (fun _ -> z3pop me) f
let z3assert me ps = List.iter (fun p -> BS.time "Z3.ass_cst" (Z3.assert_cnstr me.c) p) ps


(* COMMENTING OUT FOR PROFILING 
let valid me p =
  let _ = BS.time "push" (push me) [(Z3.mk_not me.c p)] in
  let rv = Timeout.do_timeout !Constants.z3_timeout unsat me in
  let rv = match rv with Some x -> x
                       | None -> failwith "UNRECOVERABLE FIXPOINT ERROR: Z3 TIMED OUT" in
  let _ = pop me in
  rv
*)
(*
let valid me p =
  let _ = BS.time "push" (push me) [(Z3.mk_not me.c p)] in
  BS.time "unsat" unsat me 
  >> (fun _ -> pop me)
*)

let z3Valid me p = 
  z3Do me begin fun _ ->
    z3assert me [Z3.mk_not me.c p];
    BS.time "unsat" unsat me 
  end

let z3Contra me p = 
  z3Do me begin fun _ ->
    z3assert me [p];
    BS.time "unsat" unsat me 
  end

let clean_decls me =
  let cs, vars' = vpop ([],me.vars) in
  let _         = me.vars <- vars'  in 
  List.iter begin function 
    | Barrier    -> failure "ERROR: TPZ3.clean_decls" 
    | Vbl _ as d -> Hashtbl.remove me.vart d 
    | Fun _ as d -> Hashtbl.remove me.funt d
  end cs

(* DEPRECATED, overall slowdown 
let min_filter me env p_imp ps =
  ps 
  |> List.rev_map (fun (x, p) -> (x, p, z3Pred me env p)) 
  |> FixMisc.cov_filter (fun x y -> BS.time "p_imp" (p_imp (fst3 x)) (fst3 y)) (thd3 <+> valid me)
  |> List.map (fun (x, xs) -> List.map fst3 (x::xs))

let filter me =  
  if !Constants.minquals then min_filter me else filter me
*)

let handle_vv me env vv = 
  Hashtbl.remove me.vart (z3Vbl env vv) (* RJ: why are we removing this? *) 

(************************************************************************)
(********************************* API **********************************)
(************************************************************************)

(* API *)
let create ts env ps consts =
  let _  = asserts (ts = []) "ERROR: TPZ3.create non-empty sorts!" in
  let c  = Z3.mk_context_x [|("MODEL", "false"); ("MODEL_PARTIAL", "true")|] in
  let me = {c     = c; 
            tint  = Z3.mk_int_sort c; 
            tbool = Z3.mk_bool_sort c; 
            tydt  = Hashtbl.create 37; 
            vart  = Hashtbl.create 37; 
            funt  = Hashtbl.create 37; 
            vars  = []; count = 0; bnd = 0} in
  let _  = List.iter (z3Pred me env <+> assert_axiom me) (axioms ++ ps) in
  let _  = if FixMisc.nonnull consts 
           then (z3Distinct me env consts |> assert_axiom me) 
  in me

(*
let set me env vv ps =
  handle_vv me env vv;
  ps |> prep_preds me env |> push me;
  (* unsat me *) false

let filter me env _ ps =
  ps 
  |> List.rev_map (fun (x, p) -> (x, p, z3Pred me env p)) 
  |> FixMisc.filter (thd3 <+> valid me)
  |> List.map (fst3 <+> FixMisc.single)

(* API *)
let set_filter (me: t) (env: So.t SM.t) (vv: Sy.t) ps p_imp qs =
  let _   = ignore(nb_set   += 1); ignore (nb_query += List.length qs) in
  let ps  = BS.time "fixdiv" (List.rev_map A.fixdiv) ps in
  match BS.time "TP set" (set me env vv) ps with 
  | true  -> 
    let _ = nb_unsatLHS += 1 in
    let _ = pop me in
    List.map (fst <+> FixMisc.single) qs 
  
  | false ->
     qs 
     |> List.rev_map   (FixMisc.app_snd A.fixdiv) 
     |> List.partition (snd <+> P.is_tauto)
     |> FixMisc.app_fst   (List.map (fst <+> FixMisc.single))
     |> FixMisc.app_snd   (BS.time "TP filter" (filter me env p_imp))
     >> (fun _ -> pop me; clean_decls me)
     |> FixMisc.uncurry (++) 

*)

(* API *)
let set_filter (me: t) (env: So.t SM.t) (vv: Sy.t) ps qs =
  let _   = ignore(nb_set   += 1); ignore (nb_query += List.length qs) in
  let _   = handle_vv me env vv  in
  let zps = prep_preds me env ps in (* DO NOT PUSH INSIDE z3Do or z3 blocks postests/ll3.c *)
  z3Do me begin fun _ ->
    let _        = z3assert me zps                               in
    let tqs, fqs = List.partition (snd <+> P.is_tauto) qs        in
    let fqs      = fqs |> List.rev_map (FixMisc.app_snd (z3Pred me env))
                       |> FixMisc.filter  (snd <+> z3Valid me)      in 
    let _        = clean_decls me                                in
    (List.map fst tqs) ++ (List.map fst fqs)
  end

(* API *)
let print_stats ppf me =
  Format.fprintf ppf
    "TP stats: sets=%d, pushes=%d, pops=%d, unsats=%d, queries=%d, count=%d, unsatLHS=%d \n" 
    !nb_set !nb_push !nb_pop !nb_unsat !nb_query (List.length me.vars) !nb_unsatLHS

(*************************************************************************)
(****************** Unsat Core for CEX generation ************************)
(*************************************************************************)

let mk_prop_var me pfx i : Z3.ast =
  i |> string_of_int
    |> (^) pfx
    |> Z3.mk_string_symbol me.c 
    |> FixMisc.flip (Z3.mk_const me.c) me.tbool 

let mk_prop_var_idx me ipa : (Z3.ast array * (Z3.ast -> 'a option)) =
  let va  = Array.mapi (fun i _ -> mk_prop_var me "uc_p_" i) ipa in
  let vm  = va 
            |> Array.map (Z3.ast_to_string me.c)
            |> FixMisc.array_to_index_list 
            |> List .map FixMisc.swap 
            |> SSM.of_list in 
  let f z = SSM.maybe_find (Z3.ast_to_string me.c z) vm
            |> FixMisc.maybe_map (fst <.> Array.get ipa) in
  (va, f)

let mk_pa me p2z pfx ics =
  ics |> List.map (FixMisc.app_snd p2z) 
      |> Array.of_list 
      |> Array.mapi (fun i (x, p) -> (x, p, mk_prop_var me pfx i))



(*
(* API *)
let unsat_cores me env p ips iqs = 
  let _  = Hashtbl.clear me.vart                                  in 
  let p2z   = A.fixdiv <+> z3Pred me env                          in
  let ipa   = ips |> List.map (FixMisc.app_snd p2z) |> Array.of_list in 
  let va, f = mk_prop_var_idx me ipa          in
  let _     = ipa |> Array.mapi (fun i (_, p) -> Z3.mk_iff me.c va.(i) p)
                  |> Array.to_list
                  |> (++) [p2z p]
                  |> Array.of_list
                  |> Z3.mk_and me.c
                  >> (fun _ -> Z3.push me.c)
                  |> Z3.assert_cnstr me.c 
  in          iqs |> List.map (FixMisc.app_snd p2z)
                  |> List.map (unsat_core_one me va f)
                  >> (fun _ -> Z3.pop me.c)

*)

(*
let unsat_core_one me (va : Z3.ast array) (f: Z3.ast -> 'a) (k, q) =
  let _  = Z3.push me.c in
  let _  = Z3.assert_cnstr me.c (Z3.mk_not me.c q) in
  let r  = match Z3.check_assumptions me.c va (Array.length va) (Array.map id va) with
           | (Z3.L_FALSE, m,_, n, ucore) 
               -> Array.map f ucore 
                  |> Array.to_list 
                  |> FixMisc.map_partial id 
           | _ -> [] in
  let _  = Z3.pop me.c  in
  (k, r)
*)

(* API *)
let unsat_core me env bgp ips =
  let _     = Hashtbl.clear me.vart                               in 
  let p2z   = A.fixdiv <+> z3Pred me env                          in
  let ipa   = ips |> List.map (FixMisc.app_snd p2z) |> Array.of_list in 
  let va, f = mk_prop_var_idx me ipa                              in
  let zp    = ipa |> Array.mapi (fun i (_, p) -> Z3.mk_iff me.c va.(i) p)
                  |> Array.to_list
                  |> (++) [p2z bgp]
                  |> Array.of_list
                  |> Z3.mk_and me.c in
  z3Do me begin fun _ ->
    let _   = z3assert me [zp] in
    let n   = Array.length va in
    let va' = Array.map id va in
    match Z3.check_assumptions me.c va n va' with
      | (Z3.L_FALSE, m,_, n, ucore) 
          -> Array.map f ucore |> Array.to_list |> FixMisc.map_partial id 
      | _ -> []
  end
 
(* API *)
let is_contra me env =  z3Pred me env <+> z3Contra me 

(* API *)
let unsat_suffix me env p ps =
  let _ = if unsat me then assertf "ERROR: unsat_suffix" in
  z3Do me begin fun _ ->
    let rec loop j = function [] -> None | zp' :: zps' -> 
      z3assert me [zp']; 
      if unsat me then Some j else loop (j-1) zps'
    in loop (List.length ps) (List.map (z3Pred me env) (p :: List.rev ps)) 
  end
 
end
