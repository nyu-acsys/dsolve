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

open Types
open Typedtree
open Format
open Asttypes

type substitution = Path.t * Predicate.pexpr
type dep_sub      = string * string

type qvar       = int
type refexpr    = substitution list * (Lqualifier.t list * qvar list)
type refinement = refexpr list

type 'a prerecref = 'a list list
type recref       = refinement prerecref

type qexpr =
  | Qconst of Lqualifier.t
  | Qvar   of qvar

type simple_refinement = substitution list * qexpr

type 'a preframe =
  | Fvar       of Ident.t * int * dep_sub list * 'a
  | Fsum       of Path.t * 'a preconstr list * 'a
  | Finductive of Path.t * 'a preparam list * 'a prerecref * 'a preconstr list * 'a
  | Frec       of Path.t * 'a preframe list * 'a prerecref * 'a
  | Fabstract  of Path.t * 'a preparam list * Ident.t * 'a
  | Farrow     of Ident.t * 'a preframe * 'a preframe

and 'a preparam  = Ident.t * 'a preframe * variance
and 'a preconstr = constructor_tag * (string * 'a preparam list)
and variance     = Covariant | Contravariant | Invariant

type param  = refinement preparam
type constr = refinement preconstr

type t = refinement preframe

exception LabelLikeFailure of t * t

(******************************************************************************)
(******************************* Pretty Printing ******************************)
(******************************************************************************)

val pprint            : formatter -> t -> unit
val pprint_fenv       : formatter -> t Liqenv.t -> unit list
val pprint_refinement : formatter -> refinement -> unit

(******************************************************************************)
(******************************** Polymorphism ********************************)
(******************************************************************************)

val generic_level : int

val begin_def                   : unit -> unit
val end_def                     : unit -> unit
val initialize_type_expr_levels : type_expr -> unit
val generalize                  : t -> t
val instantiate                 : t Liqenv.t -> t -> t -> t * t list

(******************************************************************************)
(***************************** Frame Manipulation *****************************)
(******************************************************************************)

val apply             : t -> Predicate.pexpr list -> t

val label_like        : t -> t -> t

val unfold            : t -> t
val unfold_with_shape : t -> t
val wf_unfold         : t -> t

val shape             : t -> t
val is_shape          : t -> bool
val same_shape        : t -> t -> bool

val subt              : t -> t -> (Ident.t * Ident.t) list -> (Ident.t * t) list -> bool * (Ident.t * Ident.t) list * (Ident.t * t) list
val subti             : t -> t -> bool * (Ident.t * Ident.t) list * (Ident.t * t) list
val subtis            : t -> t -> bool
val map_inst          : (Ident.t * Ident.t) list -> (Ident.t * t) list -> t -> t

(******************************************************************************)
(***************************** Frame Constructors *****************************)
(******************************************************************************)

val fresh                          : Env.t -> type_expr -> t
val fresh_without_vars             : Env.t -> type_expr -> t
val fresh_false                    : Env.t -> type_expr -> t
val fresh_variant_with_params      : Env.t -> Path.t -> t list -> t
val fresh_uninterpreted            : Env.t -> type_expr -> Path.t -> t
val fresh_builtin                  : Env.t -> type_expr -> t
val uninterpreted_constructors     : Env.t -> type_expr -> (string * t) list

val path_tuple                     : Path.t

val sum_of_params                  : Path.t -> param list -> refinement -> t
val tuple_of_frames                : t list -> refinement -> t
val abstract_of_params_with_labels :
  Ident.t list -> Path.t -> t list -> variance list -> Ident.t -> refinement -> t

(******************************************************************************)
(****************************** Frame Destructors *****************************)
(******************************************************************************)

val constr_params      : constr -> param list
val constrs_tag_params : constructor_tag -> constr list -> param list
val record_field       : t -> int -> t
val params_frames      : param list -> t list
val params_ids         : param list -> Ident.t list

(******************************************************************************)
(********************************** Iterators *********************************)
(******************************************************************************)

val map_refexprs   : (refexpr -> refexpr) -> t -> t
val map_qualifiers : (Lqualifier.t -> Lqualifier.t) -> t -> t
val iter_labels    : (Ident.t -> unit) -> t -> unit

(******************************************************************************)
(*************************** Refinement Manipulation **************************)
(******************************************************************************)

val empty_refinement     : refinement
val const_refinement     : Lqualifier.t list -> refinement
val mk_refinement        : substitution list -> Lqualifier.t list -> qvar list -> refinement
val refinement_conjuncts : (qvar -> Lqualifier.t list) -> Predicate.pexpr -> refinement -> Predicate.t list
val refinement_predicate : (qvar -> Lqualifier.t list) -> Predicate.pexpr -> refinement -> Predicate.t
val apply_solution       : (qvar -> Lqualifier.t list) -> t -> t
val refinement_qvars     : refinement -> qvar list
val refexpr_apply_subs   : substitution list -> refexpr -> refexpr
val apply_subs           : substitution list -> t -> t
val apply_refinement     : refinement -> t -> t
val append_refinement    : refinement -> t -> t
val get_refinement       : t -> refinement option 
val has_qvars            : t -> bool
val find_tag             : refinement -> constructor_tag  option
val refinement_qvars     : refinement -> qvar list
val ref_to_simples       : refinement -> (simple_refinement list * simple_refinement list)
val ref_of_simple        : simple_refinement -> refinement
val refinement_fold      : (refinement -> 'a -> 'a) -> 'a -> t -> 'a
val refinement_iter      : (refinement -> unit) -> t -> unit
val conjuncts            : (qvar -> Lqualifier.t list) -> Predicate.pexpr -> t -> Predicate.t list

(******************************************************************************)
(*********************************** Binders **********************************)
(******************************************************************************)

val fresh_binder : unit -> Ident.t

val bind         : pattern_desc -> t -> (Path.t * t) list
val env_bind     : t Liqenv.t -> pattern_desc -> t -> t Liqenv.t

(******************************************************************************)
(******************************** Environments ********************************)
(******************************************************************************)

val prune_env_funs   : t Liqenv.t -> Path.t list
val prune_background : 'a Liqenv.t -> 'a Liqenv.t

(******************************************************************************)
(********************************** Variances *********************************)
(******************************************************************************)

val translate_variance : (bool * bool * bool) -> variance
val mutable_variance   : Asttypes.mutable_flag -> variance
