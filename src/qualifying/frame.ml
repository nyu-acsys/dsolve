open Parsetree (* must be opened before typedtree *)
open Types
open Typedtree
open Btype
open Format
open Asttypes

module C = Common
module PM = C.PathMap
module T = Typetexp

type substitution = Path.t * Predicate.pexpr

type open_assignment = Top | Bottom

type qualifier_expr =
    Qvar of (Path.t * open_assignment)  (* Qualifier variable *)
  | Qconst of Qualifier.t list          (* Constant qualifier set *)

type refinement = substitution list * qualifier_expr

type t =
    Fvar of Path.t
  | Fconstr of Path.t * t list * variance list * refinement
  | Farrow of pattern_desc option * t * t
  | Ftuple of t list * refinement
  | Frecord of Path.t * (t * string * mutable_flag) list * refinement
  | Funknown

and variance = Covariant | Contravariant | Invariant

let pprint_sub ppf (path, pexp) =
  fprintf ppf "@[%s@ ->@ %a@]" (Path.name path) Predicate.pprint_pexpr pexp

let pprint_subs ppf subs =
  Oprint.print_list pprint_sub (fun ppf -> fprintf ppf ";@ ") ppf subs

let unique_name = (* Path.name *) Path.unique_name 

let pprint_refinement ppf refi =
  match refi with
    | (_, Qvar (id, _) ) ->
      fprintf ppf "%s" (unique_name id)
    | (subs, Qconst []) ->
      fprintf ppf "true"
    | (subs, Qconst quals) ->
      let preds = List.map (Qualifier.apply (Predicate.Var (Path.mk_ident "V"))) quals in
      let preds = List.map (Predicate.apply_substs subs) preds in
        Oprint.print_list Predicate.pprint (fun ppf -> fprintf ppf "@ ") ppf preds

let rec pprint_pattern ppf = function
  | Tpat_any -> fprintf ppf "_"
  | Tpat_var x -> fprintf ppf "%s" (Ident.name x)
  | Tpat_tuple pats ->
      fprintf ppf "(%a)" pprint_pattern_list pats
  | Tpat_construct (cstrdesc, pats) ->
      begin match (repr cstrdesc.cstr_res).desc with
        | Tconstr (p, _, _) -> fprintf ppf "%s(%a)" (Path.name p) pprint_pattern_list pats
        | _ -> assert false
      end
  | _ -> assert false

and pprint_pattern_list ppf pats =
  Oprint.print_list pprint_pattern (fun ppf -> fprintf ppf ", ") ppf (List.map (fun p -> p.pat_desc) pats)


let rec pprint ppf = function
  | Fvar a ->
      fprintf ppf "Var(%s)" (unique_name a)
  | Fconstr (path, [], _, r) ->
      fprintf ppf "@[{%s@ |@;<1 2>%a}@]" (Path.name path) pprint_refinement r
  | Farrow (None, f, f') ->
      fprintf ppf "@[%a@ ->@;<1 2>%a@]" pprint1 f pprint f'
  | Farrow (Some pat, f, f') ->
      fprintf ppf "@[%a:@ %a@ ->@;<1 2>%a@]" pprint_pattern pat pprint1 f pprint f'
  | Fconstr (path, l, _, r) ->
      fprintf ppf "@[{%a@ %s|@;<1 2>%a}@]" pprint_list l (unique_name path) pprint_refinement r
  | Ftuple (ts, r) ->
      fprintf ppf "@[{(%a) |@;<1 2>%a}@]" pprint_list ts pprint_refinement r
  | Frecord (id, _, r) ->
       fprintf ppf "@[{%s |@;<1 2>%a}@] " (Path.name id) pprint_refinement r
  | Funknown ->
      fprintf ppf "[unknown]"
 and pprint1 ppf = function
   | (Farrow _) as f ->
       fprintf ppf "@[(%a)@]" pprint f
   | _ as f -> pprint ppf f
 and pprint_list ppf = Oprint.print_list pprint (fun ppf -> fprintf ppf ",@;<1 2>") ppf

let translate_variance = function
  | (true, true, true) -> Invariant
  | (true, false, false) -> Covariant
  | (false, true, false) -> Contravariant
  | _ -> assert false

let transl_pref plist p = 
  let dummy () = Path.mk_ident "" in
  let fp s = 
    let b = try List.find (fun (nm, _) -> nm = s) plist with
      Not_found -> failwith (Printf.sprintf "%s not found in mlq\n" s) in
    (fun (_, p) -> p) b in
  let (v, p) =
    match p with
    | RLiteral (v, p) -> (v, p)
    | RVar s -> fp s in
  ([], Qconst([(dummy (), Path.mk_ident v, Qualdecl.transl_patpred_single p)]))

let rec translate_pframe env plist pf = 
  let vars = ref [] in
  let getvar a = try List.find (fun b -> Path.name b = a) !vars 
                   with Not_found -> let a = Path.mk_ident a in
                   let _ = vars := a::!vars in
                     a in
  let transl_pref = transl_pref plist in
  let rec transl_pframe_rec pf =
    match pf with
    | PFvar (a, r) -> Fvar (getvar a)
    | PFconstr (l, fs, r) -> transl_constr l fs r
    | PFarrow (a, b) -> Farrow (None, transl_pframe_rec a, transl_pframe_rec b)
    | PFtuple (fs, r) -> Ftuple (List.map transl_pframe_rec fs, transl_pref r)
    | PFrecord (fs, r) -> transl_record fs r 
  and transl_constr l fs r =
    let (path, decl) = try Env.lookup_type l env with
      Not_found -> raise (T.Error(Location.none, T.Unbound_type_constructor l)) in
    let _ = if List.length fs != decl.type_arity then
      raise (T.Error(Location.none, T.Type_arity_mismatch(l, decl.type_arity, List.length fs))) in
    let vs = List.map translate_variance decl.type_variance in
    let fs = List.map transl_pframe_rec fs in
    Fconstr(path, fs, vs, transl_pref r)
  and transl_record fs r =
    let fs = List.map (fun (f, s, m) -> (transl_pframe_rec f, s, m)) fs in
    let path = Path.mk_ident "_anon_record" in
    Frecord(path, fs, transl_pref r) in
  transl_pframe_rec pf

let empty_refinement = ([], Qconst [])

let false_refinement = ([], Qconst [(Path.mk_ident "false", Path.mk_ident "V", Predicate.Not (Predicate.True))])

let rec map f = function
    | (Funknown | Fvar _) as fr -> f fr
    | Fconstr (p, fs, cstrdesc, r) -> f (Fconstr (p, List.map (map f) fs, cstrdesc, r))
    | Ftuple (fs, r) -> f (Ftuple (List.map (map f) fs, r))
    | Farrow (x, f1, f2) -> f (Farrow (x, map f f1, map f f2))
    | Frecord (p, fs, r) -> f (Frecord (p, List.map (fun (fr, n, m) -> (map f fr, n, m)) fs, r))

(* Instantiate the tyvars in fr with the corresponding frames in ftemplate.
   If a variable occurs twice, it will only be instantiated with one frame; which
   one is undefined and unimportant. *)
let instantiate fr ftemplate =
  let vars = ref [] in
  let rec inst f ft =
    match (f, ft) with
      | (Fvar _, _) -> (try List.assq f !vars with Not_found -> vars := (f, ft) :: !vars; ft)
      | (Farrow (l, f1, f1'), Farrow (_, f2, f2')) ->
          Farrow (l, inst f1 f2, inst f1' f2')
      | (Fconstr (p, l, varis, r), Fconstr(p', l', _, _)) ->
          Fconstr(p, List.map2 inst l l', varis, r)
      | (Ftuple (t1s, r), Ftuple (t2s, _)) ->
          Ftuple (List.map2 inst t1s t2s, r)
      | (Frecord (p, f1s, r), Frecord (_, f2s, _)) ->
          let inst_rec (f1, name, m) (f2, _, _) = (inst f1 f2, name, m) in
            Frecord (p, List.map2 inst_rec f1s f2s, r)
      | (Funknown, Funknown) -> Funknown
      | (f1, f2) ->
          fprintf std_formatter "@[Unsupported@ types@ for@ instantiation:@;<1 2>%a@;<1 2>%a@]@."
	    pprint f1 pprint f2;
	    assert false
  in inst fr ftemplate

let fresh_refinementvar open_assn () = ([], Qvar (Path.mk_ident "k", open_assn))

let fresh_fvar () = Fvar (Path.mk_ident "a")

(* 1. Tedium ahead:
   OCaml stores information about record types in two places:
    - The type declaration stores everything that's set in stone about the
     type: what its fields are and which variables are the type parameters.
    - The type list of the Tconstr contains the actual instantiations of
     the tyvars in this instantiation of the record. *)

(* Create a fresh frame with the same shape as the type of [exp] using
   [fresh_ref_var] to create new refinement variables. *)
let fresh_with_var_fun vars env ty fresh_ref_var =
  let rec fresh_rec freshf t =
    let t = repr t in
    match t.desc with
        Tvar ->
          (try List.assq t !vars with Not_found ->
            let fv = fresh_fvar () in 
            vars := (t, fv) :: !vars; fv)
      | Tconstr(p, tyl, _) ->
          let ty_decl = Env.find_type p env in
          (match ty_decl.type_kind with
           | Type_abstract | Type_variant _ ->
               if Path.same p Predef.path_unit || Path.name p = "garbage" then Fconstr (p, [], [], ([], Qconst [])) else
                 Fconstr(p, List.map (fresh_rec freshf) tyl, List.map translate_variance ty_decl.type_variance, freshf())
           | Type_record (fields, _, _) -> (* 1 *)
               let param_map = List.combine ty_decl.type_params tyl in
               let fresh_field (name, muta, typ) =
                 let field_typ = try List.assoc typ param_map with Not_found -> typ in
                 (fresh_rec freshf field_typ, name, muta) in
               Frecord (p, List.map fresh_field fields, freshf ()))
      | Tarrow(_, t1, t2, _) -> Farrow (None, fresh_rec freshf t1, fresh_rec freshf t2)
      | Ttuple ts -> Ftuple (List.map (fresh_rec freshf) ts, freshf ())
      | _ -> fprintf err_formatter "@[Warning: Freshing unsupported type]@."; Funknown
  in fresh_rec fresh_ref_var (repr ty)

(* Create a fresh frame with the same shape as the given type
   [ty]. Uses type environment [env] to find type declarations.

   You probably want to consider using fresh_with_labels instead of this
   for subtype constraints. *)
let fresh env ty = fresh_with_var_fun (ref []) env ty (fresh_refinementvar Top)

(* Create a fresh frame with the same shape as the given type [ty].
   No refinement variables are created - all refinements are initialized
   to true. *)
let fresh_without_vars env ty = fresh_with_var_fun (ref []) env ty (fun _ -> empty_refinement)

let fresh_unconstrained env ty = fresh_with_var_fun (ref []) env ty (fresh_refinementvar Bottom)

let fresh_constructor env cstrdesc = function
  | Fconstr (_, fl, _, _) ->
      let tyargs = match cstrdesc.cstr_res.desc with Tconstr(_, args, _) -> args | _ -> assert false in
      let argmap = ref (List.combine (List.map repr tyargs) fl) in
        List.map (fun t -> fresh_with_var_fun argmap env t (fresh_refinementvar Top)) cstrdesc.cstr_args
  | _ -> assert false

(* Label all the function formals in [f] with their corresponding labels in
   [f'].  Obviously, they are expected to be of the same shape; also, [f]
   must be completely unlabeled (as frames are after creation by fresh). *)
let rec label_like f f' =
  match (f, f') with
    | (Fvar _, Fvar _) | (Fconstr _, Fconstr _) | (Funknown, Funknown) -> f
    | (Farrow (None, f1, f1'), Farrow(l, f2, f2')) ->
        Farrow (l, label_like f1 f2, label_like f1' f2')
    | (Ftuple (t1s, r), Ftuple (t2s, _)) ->
        Ftuple (List.map2 label_like t1s t2s, r)
    | (Frecord (p1, f1s, r), Frecord (p2, f2s, _)) when Path.same p1 p2 ->
        let label_rec (f1, n, muta) (f2, _, _) = (label_like f1 f2, n, muta) in
          Frecord (p1, List.map2 label_rec f1s f2s, r)
    | _ -> assert false

(* Create a fresh frame with the same shape as [exp]'s type and [f],
   and the same labels as [f]. *)
let fresh_with_labels env ty f = label_like (fresh env ty) f

let apply_substitution_map sub = function
  | Fconstr (p, fs, cstrs, (subs, qe)) -> Fconstr (p, fs, cstrs, (sub :: subs, qe))
  | Frecord (p, fs, (subs, qe)) -> Frecord (p, fs, (sub :: subs, qe))
  | f -> f

let apply_substitution sub f = map (apply_substitution_map sub) f

let refinement_apply_solution solution = function
  | (subs, Qvar (k, _)) -> (subs, Qconst (solution k))
  | r -> r

let apply_solution_map solution = function
  | Fconstr (path, fl, cstrs, r) -> Fconstr (path, fl, cstrs, refinement_apply_solution solution r)
  | Frecord (path, fs, r) -> Frecord (path, fs, refinement_apply_solution solution r)
  | Ftuple (fs, r) -> Ftuple (fs, refinement_apply_solution solution r)
  | f -> f

let apply_solution solution fr = map (apply_solution_map solution) fr

let refinement_conjuncts solution qual_expr (subs, qualifiers) =
  let quals = match qualifiers with
    | Qvar (k, _) -> (try solution k with Not_found -> assert false)
    | Qconst qs -> qs
  in
  let unsubst = List.map (Qualifier.apply qual_expr) quals in
    List.map (Predicate.apply_substs subs) unsubst

let ref_var = function
  | (_, Qvar (k, _)) -> Some k
  | _ -> None

let rec refinement_vars = function
  | Fconstr (_, _, _, r) -> C.maybe_cons (ref_var r) []
  | Frecord (_, fs, r) ->
      C.maybe_cons (ref_var r) (List.fold_left (fun r (f, _, _) -> refinement_vars f @ r) [] fs)
  | Ftuple (fs, r) ->
      C.maybe_cons (ref_var r) (List.fold_left (fun r f -> refinement_vars f @ r) [] fs)
  | _ -> []

let apply_refinement r = function
  | Fconstr (p, fl, varis, _) -> Fconstr (p, fl, varis, r)
  | Frecord (p, fs, _) -> Frecord (p, fs, r)
  | Ftuple (fs, _) -> Ftuple (fs, r)
  | f -> f

let refinement_predicate solution qual_var refn =
  Predicate.big_and (refinement_conjuncts solution qual_var refn)

let rec conjunct_fold cs solution qual_expr = function
  | Fconstr(_, _, _, r) -> refinement_conjuncts solution qual_expr r @ cs
  | Frecord (p, fs, r) ->
      let subframe_fold b (f, name, _) =
        conjunct_fold b solution (Predicate.Field (name, qual_expr)) f
      in refinement_conjuncts solution qual_expr r @ List.fold_left subframe_fold cs fs
  | Ftuple (fs, r) ->
      let subframe_fold i b f =
        conjunct_fold b solution (Predicate.Proj (i, qual_expr)) f
      in refinement_conjuncts solution qual_expr r @ C.fold_lefti subframe_fold cs fs
  | _ -> cs

let rec conjuncts solution qual_expr fr =
  conjunct_fold [] solution qual_expr fr

let predicate solution qual_expr f =
  Predicate.big_and (conjuncts solution qual_expr f)
