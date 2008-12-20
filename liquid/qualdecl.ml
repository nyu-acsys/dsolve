open Parsetree
open Predicate

module C = Common
module Le = Lightenv
module F = Frame

let rel_star = [Ge; Le; Ne]
let op_star = [Plus; Minus; Times; Div]
let transl_ops ops =
  match ops with
      [] -> op_star
    | _ -> List.map transl_op ops
let transl_rels rels =
  match rels with
      [] -> rel_star
    | _ -> List.map transl_rel rels

let find_key_by_name s env =
  Le.filterkeylist (fun p _ -> Path.name p = s) env

let map_key_by_name f env =
  Le.mapfilter (fun p _ -> if f p then Some (Var p) else None) env 

let env_by_type_f f t m =
  Le.maplistfilter (fun v r -> f v (F.subtis t r)) m

let dummy_frame = F.Fabstract (Predef.path_unit, [], Ident.create "", F.empty_refinement)

let ck_consistent patpred pred =
  let m = ref [] in
  let addm a = m := a::!m in
  let gtm (a, b) = 
    try List.find (fun (c, _) -> a = c) !m 
      with Not_found -> addm (a, b); (a,b) in
  let ckm (a, b) = (fun (_, d) -> b = d) (gtm (a, b)) in
  let rec ck_expr_rec pat pred =
    match (pat.ppredpatexp_desc, pred) with
      | (Ppredpatexp_var (_), Var(_))
      | (Ppredpatexp_any_int, PInt (_)) 
      | (Ppredpatexp_int (_), PInt (_)) ->
	        true
      | (Ppredpatexp_funapp (_, es), FunApp (_, el)) ->
          List.for_all2 ck_expr_rec es el
      | (Ppredpatexp_binop (e1, _, e2), Binop (e1', _, e2')) ->
          ck_expr_rec e1 e1' && ck_expr_rec e2 e2'  
      | (Ppredpatexp_field (_, e1), Field(_, e1')) ->
          ck_expr_rec e1 e1'
      | (Ppredpatexp_mvar (x), Var(y)) ->
          ckm (x, Path.name y)
      | (Ppredpatexp_ite (t, e1, e2), Ite (t', e1', e2')) ->
          ck_pred_rec t t' && ck_expr_rec e1 e1' && ck_expr_rec e2 e2'
      | _ -> assert false
  and ck_pred_rec pat pred =
    match (pat.ppredpat_desc, pred) with
      | (Ppredpat_true, True) -> 
          true
      | (Ppredpat_atom (e1, _, e2), Atom (ee1, _, ee2)) ->
          ck_expr_rec e1 ee1 && ck_expr_rec e2 ee2
      | (Ppredpat_not (p), Not (pp)) -> 
          ck_pred_rec p pp
      | (Ppredpat_or (p1, p2), Or (pp1, pp2))
      | (Ppredpat_and (p1, p2), And (pp1, pp2)) -> 
          ck_pred_rec p1 pp1 && ck_pred_rec p2 pp2 
      | (Ppredpat_exists (ps, q), Exists (ps', q'))
      | (Ppredpat_forall (ps, q), Forall (ps', q')) ->
          ck_pred_rec q q'
      | (Ppredpat_iff (e, p), Iff (e', p')) ->
          ck_pred_rec e e' && ck_pred_rec p p'
      | (Ppredpat_boolexp e, Boolexp e') ->
          ck_expr_rec e e'
      | (Ppredpat_implies (a, b), Implies (a', b')) ->
          ck_pred_rec a a' && ck_pred_rec b b' 
      | _ -> assert false in
    ck_pred_rec patpred pred

let rec transl_patpred f env (v, nv) tymap constset p =
  let untyped = ref false in
  let vm = ref [] in
  let rec transl_expr_rec pe =
    match pe.ppredpatexp_desc with
      | Ppredpatexp_int (n) ->
          List.rev_map (fun p -> PInt p) n
      | Ppredpatexp_any_int ->
          List.rev_map (fun p -> PInt p) constset
      | Ppredpatexp_var (y) ->
          let z = f y in
          let y = 
            if C.maybe_bool z then [C.maybe z] else
            C.fast_flap 
              (fun y -> let y = C.l_to_s y in if y = v then [Var nv]
                else map_key_by_name (fun p -> Path.name p = y) env) y in
          if C.empty_list y then assert false else y
      | Ppredpatexp_mvar (y) ->
          begin
          try [Var (List.assoc y !vm)]
            with Not_found ->
              untyped := true;
              if C.empty_list (Le.all env) then assert false else ();
              List.rev_map (fun p -> Var p) (Le.all env)
          end
      | Ppredpatexp_funapp (f, es) ->
          let es = List.rev_map transl_expr_rec es in
          let f' = List.hd (find_key_by_name (C.l_to_s f) env) in
          List.rev_map (fun e -> FunApp (f', e)) (C.rev_perms es)
      | Ppredpatexp_binop (e1, ops, e2) ->
          let (e1, e2) = C.app_pr transl_expr_rec (e1, e2) in
          let es = List.rev_map (function [e1; e2] -> (fun o -> Binop (e1, o, e2)) | _ -> assert false)
              (C.rev_perms [e2; e1]) in
          let ops = transl_ops ops in
          C.fast_flap (fun e -> List.rev_map e ops) es
      | Ppredpatexp_field (f, e1) ->
          let es = List.rev_map (fun f -> (fun e1 -> Field (f, e1))) (find_key_by_name f env) in
          let e1 = transl_expr_rec e1 in
          C.fast_flap (fun e -> List.rev_map e e1) es 
      | Ppredpatexp_ite (t, e1, e2) ->
          let (e1, e2) = C.app_pr transl_expr_rec (e1, e2) in
          let t = transl_pred_rec t in
          let es = List.rev_map
            (function [e1; e2]  -> (fun t -> Ite (t, e1, e2)) | _ -> assert false)
              (C.rev_perms [e2; e1]) in
          C.fast_flap (fun e -> List.rev_map e t) es
  and transl_pred_rec pd =
    match pd.ppredpat_desc with
      | Ppredpat_true ->
          [True]
      | Ppredpat_atom (e1, rels, e2) ->
          let (e1, e2) = C.app_pr transl_expr_rec (e1, e2) in
          let es = List.rev_map (function [e1; e2] -> (fun r -> Atom (e1, r, e2)) | _ -> assert false)
            (C.rev_perms [e2; e1]) in
          let rels = transl_rels rels in
          C.fast_flap (fun e -> List.rev_map e rels) es
      | Ppredpat_not (p) ->
          List.rev_map (fun p -> Not p) (transl_pred_rec p)
      | Ppredpat_implies (p1, p2) ->
          permute_pred_pair (fun p1 p2 -> Implies (p1, p2)) p1 p2
      | Ppredpat_and (p1, p2) ->
          permute_pred_pair (fun p1 p2 -> And (p1, p2)) p1 p2
      | Ppredpat_or (p1, p2) ->
          permute_pred_pair (fun p1 p2 -> Or (p1, p2)) p1 p2
      | Ppredpat_forall (ps, q) ->
          let (bs, ps) = List.split ps in
          let bs = List.rev_map (fun b -> (Path.mk_ident b, dummy_frame)) bs in
          let ps = List.combine (fst (List.split bs)) ps in
          let env = Le.addn bs env in
          List.rev_map (fun p -> Forall (ps, p))
            (transl_patpred (fun x -> None) env (v, nv) tymap constset q)
      | Ppredpat_exists (ps, q) ->
          let (bs, ps) = List.split ps in
          let bs = List.rev_map (fun b -> (Path.mk_ident b, dummy_frame)) bs in
          let ps = List.combine (fst (List.split bs)) ps in
          let env = Le.addn bs env in
          List.rev_map (fun p -> Exists (ps, p))
            (transl_patpred (fun x -> None) env (v, nv) tymap constset q)
      | Ppredpat_iff (e, p) ->
          permute_pred_pair (fun e p -> Iff (e, p)) e p
      | Ppredpat_boolexp e ->
          List.rev_map (fun p -> Boolexp p) (transl_expr_rec e)
  and permute_pred_pair f e p =
    let (e, p) = C.app_pr transl_pred_rec (e, p) in
    List.rev_map (function [e; p] -> f e p | _ -> assert false) (C.rev_perms [p; e]) in
  let ts = C.rev_perms (List.rev_map (fun (v, t) -> env_by_type_f (fun n b -> if b then Some (v, n) else None) t env) tymap) in 
  let p' = C.fast_flap (fun t -> vm := t; transl_pred_rec p) ts in
  if !untyped then List.filter (ck_consistent p) p' else p'

let transl_patpred_map f pred = transl_patpred f Le.empty ("", C.qual_test_var) [] [] pred

let transl_patpred = transl_patpred (fun x -> None)

let transl_patpred_simple env pred = transl_patpred env ("", C.qual_test_var) [] [] pred 

let transl_pref plist env (v, p) = 
  let valu = C.qual_test_var in
  [([], ([(C.dummy_id, valu, transl_patpred env (v, valu) [] [] p)], []))]

let rec pat_map_pred_subexps f p =
  let rec sub p = 
    let desc = match p.ppredpat_desc with
      | Ppredpat_atom (e1, r, e2) -> Ppredpat_atom (pat_map_exps f e1, r, pat_map_exps f e2)
      | Ppredpat_not (p) -> Ppredpat_not (sub p)
      | Ppredpat_and (p1, p2) -> Ppredpat_and (sub p1, sub p2)
      | Ppredpat_implies (p1, p2) -> Ppredpat_and (sub p1, sub p2)
      | Ppredpat_or (p1, p2) -> Ppredpat_or (sub p1, sub p2)
      | Ppredpat_forall (ps, p) -> Ppredpat_forall (ps, sub p)
      | Ppredpat_exists (ps, p) -> Ppredpat_exists (ps, sub p)
      | Ppredpat_iff (p1, p2) -> Ppredpat_iff (sub p1, sub p2)
      | Ppredpat_boolexp (e) -> Ppredpat_boolexp (pat_map_exps f e)
      | Ppredpat_true -> Ppredpat_true in
    {ppredpat_desc = desc; ppredpat_loc = p.ppredpat_loc} in
  sub p

and pat_map_exps f e =
  let rec sub e =
    let desc = match e.ppredpatexp_desc with
      | Ppredpatexp_funapp (n, es) -> f (Ppredpatexp_funapp (n, List.map sub es))
      | Ppredpatexp_binop (e1, os, e2) -> f (Ppredpatexp_binop (sub e1, os, sub e2))
      | Ppredpatexp_field (s, e) -> f (Ppredpatexp_field (s, sub e))
      | Ppredpatexp_ite (p, e1, e2) -> f (Ppredpatexp_ite (pat_map_pred_subexps f p, sub e1, sub e2))
      | e -> f e in
    {ppredpatexp_desc = desc; ppredpatexp_loc = e.ppredpatexp_loc} in
  sub e

let pat_map_funs_un f = function
  | Ppredpatexp_funapp (n, es) -> Ppredpatexp_funapp (f n, es)
  | e -> e

let pat_map_funs f p =
  pat_map_pred_subexps (pat_map_funs_un f) p 

let pat_pexp_map_funs f e =
  pat_map_exps (pat_map_funs_un f) e
