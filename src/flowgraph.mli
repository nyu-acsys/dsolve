open Graph
open Expr


type qual = string

type callsite = int

type elabel =
      Call of callsite
    | Return of callsite


type vlabel =
    ExprId of expr_id
  | VarName of string
  | NonExpr of string

module Vertex:
sig
  type t = vlabel
  val compare : 'a -> 'a -> int
  val hash : 'a -> int
  val equal : 'a -> 'a -> bool
  val default : 'a option
end

module Edge :
sig
  type t = elabel option
  val compare : 'a -> 'a -> int
  val hash : 'a -> int
  val equal : 'a -> 'a -> bool
  val default : 'a option
end

(* pmr: should these signatures be fixed? *)
module FlowGraph :
  sig
    type t = Graph.Persistent.Digraph.ConcreteLabeled(Vertex)(Edge).t
    module V :
      sig
        type t = Graph.Persistent.Digraph.ConcreteLabeled(Vertex)(Edge).V.t
        val compare : t -> t -> int
        val hash : t -> int
        val equal : t -> t -> bool
        type label = Vertex.t
        val create : label -> t
        val label : t -> label
      end
    type vertex = V.t
    module E :
      sig
        type t = Graph.Persistent.Digraph.ConcreteLabeled(Vertex)(Edge).E.t
        val compare : t -> t -> int
        type vertex = V.t
        val src : t -> vertex
        val dst : t -> vertex
        type label = Edge.t
        val create : vertex -> label -> vertex -> t
        val label : t -> label
      end
    type edge = E.t
    val is_directed : bool
    val is_empty : t -> bool
    val nb_vertex : t -> int
    val nb_edges : t -> int
    val out_degree : t -> vertex -> int
    val in_degree : t -> vertex -> int
    val mem_vertex : t -> vertex -> bool
    val mem_edge : t -> vertex -> vertex -> bool
    val mem_edge_e : t -> edge -> bool
    val find_edge : t -> vertex -> vertex -> edge
    val succ : t -> vertex -> vertex list
    val pred : t -> vertex -> vertex list
    val succ_e : t -> vertex -> edge list
    val pred_e : t -> vertex -> edge list
    val iter_vertex : (vertex -> unit) -> t -> unit
    val iter_edges : (vertex -> vertex -> unit) -> t -> unit
    val fold_vertex : (vertex -> 'a -> 'a) -> t -> 'a -> 'a
    val fold_edges : (vertex -> vertex -> 'a -> 'a) -> t -> 'a -> 'a
    val map_vertex : (vertex -> vertex) -> t -> t
    val iter_edges_e : (edge -> unit) -> t -> unit
    val fold_edges_e : (edge -> 'a -> 'a) -> t -> 'a -> 'a
    val iter_succ : (vertex -> unit) -> t -> vertex -> unit
    val iter_pred : (vertex -> unit) -> t -> vertex -> unit
    val fold_succ : (vertex -> 'a -> 'a) -> t -> vertex -> 'a -> 'a
    val fold_pred : (vertex -> 'a -> 'a) -> t -> vertex -> 'a -> 'a
    val iter_succ_e : (edge -> unit) -> t -> vertex -> unit
    val fold_succ_e : (edge -> 'a -> 'a) -> t -> vertex -> 'a -> 'a
    val iter_pred_e : (edge -> unit) -> t -> vertex -> unit
    val fold_pred_e : (edge -> 'a -> 'a) -> t -> vertex -> 'a -> 'a
    val empty : t
    val add_vertex : t -> vertex -> t
    val remove_vertex : t -> vertex -> t
    val add_edge : t -> vertex -> vertex -> t
    val add_edge_e : t -> edge -> t
    val remove_edge : t -> vertex -> vertex -> t
    val remove_edge_e : t -> edge -> t

    val vertices : t -> vertex list

    val graph_attributes : t -> Graphviz.DotAttributes.graph list
    val default_vertex_attributes : t -> Graphviz.DotAttributes.vertex list
    val default_edge_attributes : t -> Graphviz.DotAttributes.edge list
    val vertex_name : vertex -> string
    val vertex_attributes : vertex -> Graphviz.DotAttributes.vertex list
    val edge_attributes : edge -> Graphviz.DotAttributes.edge list
    val get_subgraph : t -> Graphviz.DotAttributes.subgraph option
  end

module FlowGraphPrinter :
  sig
    val fprint_graph : Format.formatter -> FlowGraph.t -> unit
    val output_graph : Pervasives.out_channel -> FlowGraph.t -> unit
  end


type labelled_qual = QualFrom of qual * (FlowGraph.E.t option)

module LabelledQual :
  sig
    type t = labelled_qual
    val compare : 'a -> 'a -> int
  end

module LabelledQualSet :
  sig
    type elt = LabelledQual.t
    type t = Set.Make(LabelledQual).t
    val empty : t
    val is_empty : t -> bool
    val mem : elt -> t -> bool
    val add : elt -> t -> t
    val singleton : elt -> t
    val remove : elt -> t -> t
    val union : t -> t -> t
    val inter : t -> t -> t
    val diff : t -> t -> t
    val compare : t -> t -> int
    val equal : t -> t -> bool
    val subset : t -> t -> bool
    val iter : (elt -> unit) -> t -> unit
    val fold : (elt -> 'a -> 'a) -> t -> 'a -> 'a
    val for_all : (elt -> bool) -> t -> bool
    val exists : (elt -> bool) -> t -> bool
    val filter : (elt -> bool) -> t -> t
    val partition : (elt -> bool) -> t -> t * t
    val cardinal : t -> int
    val elements : t -> elt list
    val min_elt : t -> elt
    val max_elt : t -> elt
    val choose : t -> elt
    val split : elt -> t -> t * bool * t
  end

module EdgeSet:
  sig
    type elt = FlowGraph.E.t
    type t = Set.Make(FlowGraph.E).t
    val empty : t
    val is_empty : t -> bool
    val mem : elt -> t -> bool
    val add : elt -> t -> t
    val singleton : elt -> t
    val remove : elt -> t -> t
    val union : t -> t -> t
    val inter : t -> t -> t
    val diff : t -> t -> t
    val compare : t -> t -> int
    val equal : t -> t -> bool
    val subset : t -> t -> bool
    val iter : (elt -> unit) -> t -> unit
    val fold : (elt -> 'a -> 'a) -> t -> 'a -> 'a
    val for_all : (elt -> bool) -> t -> bool
    val exists : (elt -> bool) -> t -> bool
    val filter : (elt -> bool) -> t -> t
    val partition : (elt -> bool) -> t -> t * t
    val cardinal : t -> int
    val elements : t -> elt list
    val min_elt : t -> elt
    val max_elt : t -> elt
    val choose : t -> elt
    val split : elt -> t -> t * bool * t
  end


module QualMap :
  sig
    type key = FlowGraph.V.t
    type 'a t = 'a Map.Make(FlowGraph.V).t
    val empty : 'a t
    val is_empty : 'a t -> bool
    val add : key -> 'a -> 'a t -> 'a t
    val find : key -> 'a t -> 'a
    val remove : key -> 'a t -> 'a t
    val mem : key -> 'a t -> bool
    val iter : (key -> 'a -> unit) -> 'a t -> unit
    val map : ('a -> 'b) -> 'a t -> 'b t
    val mapi : (key -> 'a -> 'b) -> 'a t -> 'b t
    val maplist: (key -> 'a -> 'b) -> 'a t -> 'b list
    val fold : (key -> 'a -> 'b -> 'b) -> 'a t -> 'b -> 'b
    val compare : ('a -> 'a -> int) -> 'a t -> 'a t -> int
    val equal : ('a -> 'a -> bool) -> 'a t -> 'a t -> bool
    val union_disjoint : 'a t -> 'a t -> 'a t
  end

exception InvalidReturnEdge

val find_backedges: FlowGraph.t -> EdgeSet.t

val propagate_vertex_qualifiers: FlowGraph.t -> LabelledQualSet.t QualMap.t -> LabelledQualSet.t QualMap.t

val string_of_vlabel: vlabel -> string

val var_vertex: string -> FlowGraph.V.t
val expr_vertex: expr -> FlowGraph.V.t
val vertex_quals: LabelledQualSet.t QualMap.t -> FlowGraph.V.t -> LabelledQualSet.t
val expr_quals: LabelledQualSet.t QualMap.t -> expr -> qual list
val qualmap_definite_quals: LabelledQualSet.t QualMap.t -> (FlowGraph.V.t * qual list) list
