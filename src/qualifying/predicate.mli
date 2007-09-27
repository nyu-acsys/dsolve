type binop =
    Plus
  | Minus
  | Times

type binrel =
    Eq
  | Ne
  | Lt
  | Le 

type pexpr =   
    PInt of int 
  | Var of Ident.t
  | Pvar of Ident.t * int
  | FunApp of string * pexpr
  | Binop of pexpr * binop * pexpr 

type predicate =  
    True
  | Atom of pexpr * binrel * pexpr 
  | Not of predicate
  | And of predicate * predicate 
  | Or of predicate * predicate 

val big_and: predicate list -> predicate
val big_or: predicate list -> predicate
val equals: (pexpr * pexpr) -> predicate

val predicate_subst: pexpr -> Ident.t -> predicate -> predicate
val predicate_vars: predicate -> Ident.t list
(* pmr: change to plain old instantiate *)
val instantiate_named_vars: (string * Ident.t) list -> predicate -> predicate
(*
val parse_predicate: Parsetree.predicate -> predicate

val pprint_pexpr: pexpr -> string
*)
val pprint_predicate: predicate -> string

