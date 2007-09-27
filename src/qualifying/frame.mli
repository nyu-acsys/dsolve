open Types
open Predicate

type substitution = Ident.t * pexpr

type qualifier_expr =
    Qvar of Qualifier.t list * Ident.t  (* Qualifier variable with list of assignable
                                           qualifiers *)
  | Qconst of Qualifier.t list          (* Constant qualifier set *)

type refinement = substitution list * qualifier_expr

type frame_desc =
    Fvar
  | Fconstr of Path.t * frame_expr list * refinement
  | Farrow of Ident.t * frame_expr * frame_expr

and frame_expr = frame_desc ref

val fresh: 'a Lightenv.t -> Qualifier.t list -> type_expr -> frame_expr
val instantiate: frame_expr -> frame_expr -> unit
val apply_substitution: substitution -> frame_expr -> frame_expr

