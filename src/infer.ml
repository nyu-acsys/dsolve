open Expr
open Type
open Predicate
open Constraint


exception Unify


type typconst = TypEq of typ * typ


let rec const_subst_tyvar b a = function
    [] ->
      []
  | TypEq(t1, t2)::cs ->
      TypEq(typ_subst_tyvar b a t1,
	    typ_subst_tyvar b a t2)::(const_subst_tyvar b a cs)


let rec occurs a = function
    TyVar a' ->
      a = a'
  | Int _ ->
      false
  | Arrow(_, t, t') ->
      (occurs a t) || (occurs a t')


let rec unify = function
    [] ->
      fun t -> t
  | TypEq(t1, t2)::cs ->
      match (t1, t2) with
	  (TyVar a, t)
	| (t, TyVar a) ->
	    if (not (occurs a t)) || t1 = t2 then
	      let cs' = const_subst_tyvar t a cs in
	      let unifsub = unify cs' in
		fun t' -> unifsub (typ_subst_tyvar t a t')
	    else
	      raise Unify
	| (Arrow(_, t1, t1'), Arrow(_, t2, t2')) ->
	    unify (TypEq(t1, t2)::TypEq(t1', t2')::cs)
	| (Int _, Int _) ->
	    unify cs
	| _ ->
	    raise Unify


let type_vars typ =
  let rec type_vars_rec t vars =
    match t with
	TyVar a ->
	  a::vars
      | Int _ ->
	  []
      | Arrow(_, t1, t2) ->
	  let vars' = type_vars_rec t1 vars in
	    type_vars_rec t2 vars'
  in
    type_vars_rec typ []


let fresh_tyvar = Misc.make_get_fresh (fun x -> TyVar x)
let fresh_bindvar = Misc.make_get_fresh (fun x -> "_" ^ x)


module Expr = struct
  type t = expr
  let compare = compare
  let hash = Hashtbl.hash
  let equal = (==)
end


module ExprMap = Map.Make(Expr)


let maplist f sm =
  ExprMap.fold (fun k v r -> (f k v)::r) sm []


let pprint_shapemap smap =
  let shapes = maplist (fun e t -> (pprint_expr e) ^ "\n::> " ^ (pprint_type t)) smap in
    Misc.join shapes "\n\n"


let infer_shape exp =
  let rec infer_rec e tenv constrs shapemap =
    let (t, cs, sm) =
      match e with
	  Num(_, _) ->
	    (Int [], constrs, shapemap)
	| ExpVar(x, _) ->
	    let tx = List.assoc x tenv in
	      (tx, constrs, shapemap)
	| If(c, e1, e2, _) ->
	    let (tc, constrsc, sm) = infer_rec c tenv constrs shapemap in
	    let (t1, constrs1, sm') = infer_rec e1 tenv constrsc sm in
	    let (t2, constrs2, sm'') = infer_rec e2 tenv constrs1 sm' in
	    let t = fresh_tyvar() in
	      (t, TypEq(t1, t)::TypEq(t2, t)::TypEq(tc, Int [])::constrs2, sm'')
	| App(e1, e2, _) ->
	    let (t1, constrs1, sm') = infer_rec e1 tenv constrs shapemap in
	    let (t2, constrs2, sm'') = infer_rec e2 tenv constrs1 sm' in
	    let returnty = fresh_tyvar() in
	    let funty = Arrow(fresh_bindvar(), t2, returnty) in
	      (returnty, TypEq(t1, funty)::constrs2, sm'')
	| Abs(x, _, e, _) ->
	    let t = fresh_tyvar () in
	    let newtenv = (x, t)::tenv in
	    let (t', constrs, sm') = infer_rec e newtenv constrs shapemap in
	      (Arrow(x, t, t'), constrs, sm')
	| Let(x, _, ex, e, _) ->
	    let (tx, constrsx, sm') = infer_rec ex tenv constrs shapemap in
	    let newtenv = (x, tx)::tenv in
	    let (te, constrse, sm'') = infer_rec e newtenv constrsx sm' in
	      (te, constrse, sm'')
        | LetRec(f, _, ex, e, _) ->
            let tf = fresh_tyvar() in
            let tenv' = (f, tf)::tenv in
            let (tf', constrs'', sm'') = infer_rec ex tenv' constrs shapemap in
            let (te, constrs', sm') = infer_rec e tenv' constrs'' sm'' in
              (te, TypEq(tf, tf')::constrs', sm')
        | Cast(_, _, e, _) ->
            infer_rec e tenv constrs shapemap
    in
      (t, cs, ExprMap.add e t sm)
  in
  let (t, constrs, smap') = infer_rec exp Builtins.types [] ExprMap.empty in
  let sub = unify constrs in
  let smap = ExprMap.map sub smap' in
    smap


let subtype_constraints exp quals shapemap =
  let fresh_frame e =
    let rec fresh_frame_rec = function
	Arrow(x, t, t') ->
	  FArrow(x, fresh_frame_rec t, fresh_frame_rec t')
      | _ ->
	  fresh_framevar()
    in
      fresh_frame_rec (ExprMap.find e shapemap)
  in
  let rec constraints_rec e env guard constrs framemap =
    let (f, cs, fm) =
      match e with
	  Num(n, _) ->
            let f = FInt([], [("inteq", PredOver("_X", equals(Var "_X", PInt n)))]) in
	      (f, constrs, framemap)
        | ExpVar(x, _) ->
            let feq =
              match ExprMap.find e shapemap with
                  Int _ ->
                    FInt([], [("vareq", PredOver("_X", equals(Var "_X", Var x)))])
                | _ ->
                    List.assoc x env
            in
            let f = fresh_frame e in
	      (f, SubType(env, guard, feq, f)::constrs, framemap)
        | Abs(x, _, e', _) ->
	    begin match fresh_frame e with
	        FArrow(_, f, _) ->
		  let env' = (x, f)::env in
		  let (f'', constrs', fm') = constraints_rec e' env' guard constrs framemap in
                  let f' = fresh_frame e' in
		    (FArrow(x, f, f'), SubType(env, guard, f'', f')::constrs', fm')
	      | _ ->
		  failwith "Fresh frame has wrong shape - expected arrow"
	    end
        | App(e1, e2, _) ->
	    begin match constraints_rec e1 env guard constrs framemap with
	        (FArrow(x, f, f'), constrs', fm') ->
		  let (f2, constrs'', fm'') = constraints_rec e2 env guard constrs' fm' in
		  let pe2 = expr_to_predicate_expression e2 in
		  let f'' = frame_apply_subst pe2 x f' in
		    (f'', SubType(env, guard, f2, f)::constrs'', fm'')
	      | _ ->
		  failwith "Subexpression frame has wrong shape - expected arrow"
	    end
        | If(e1, e2, e3, _) ->
            let f = fresh_frame e in
            let (f1, constrs''', fm''') = constraints_rec e1 env guard constrs framemap in
            let guardvar = fresh_bindvar() in
            let env' = (guardvar, f1)::env in
            let guardp = equals(Var guardvar, PInt 1) in
            let guard2 = And(guardp, guard) in
            let (f2, constrs'', fm'') = constraints_rec e2 env' guard2 constrs''' fm''' in
            let guard3 = And(Not(guardp), guard) in
            let (f3, constrs', fm') = constraints_rec e3 env' guard3 constrs'' fm'' in
              (f, SubType(env', guard2, f2, f)::SubType(env', guard3, f3, f)::constrs', fm')
        | Let(x, _, e1, e2, _) ->
            let (f1, constrs'', fm'') = constraints_rec e1 env guard constrs framemap in
            let env' = (x, f1)::env in
            let (f2, constrs', fm') = constraints_rec e2 env' guard constrs'' fm'' in
            let f = fresh_frame e in
              (f, SubType(env', guard, f2, f)::constrs', fm')
        | LetRec(f, _, e1, e2, _) ->
            let f1 = fresh_frame e1 in
            let env' = (f, f1)::env in
            let (f1', constrs'', fm'') = constraints_rec e1 env' guard constrs framemap in
            let (f2, constrs', fm') = constraints_rec e2 env' guard constrs'' fm'' in
            let f = fresh_frame e in
              (f, SubType(env', guard, f2, f)::SubType(env', guard, f1', f1)::constrs', fm')
        | Cast(t1, t2, e, _) ->
            let (f, constrs', fm') = constraints_rec e env guard constrs framemap in
            let (f1, f2) = (type_to_frame t1, type_to_frame t2) in
              (f2, SubType(env, guard, f, f1)::constrs', fm')
    in
      (f, cs, ExprMap.add e f fm)
  in
    constraints_rec exp Builtins.frames True [] ExprMap.empty


let infer_types exp quals =
  let shapemap = infer_shape exp in
  let (fr, constrs, fmap) = subtype_constraints exp quals shapemap in
  let solution = solve_constraints quals constrs in
  let _ = Printf.printf "%s\n\n" (pprint_frame fr) in
  let expr_to_type e =
    frame_to_type (frame_apply_solution solution (ExprMap.find e fmap))
  in
    expr_to_type
