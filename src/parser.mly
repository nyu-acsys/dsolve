%{

open Qualgraph
open Flowgraph
open Expr
open Type

%}


%token ARROW
%token BANG
%token BOOL
%token BOTTOM
%token COLON
%token DOT
%token ELSE
%token EOL
%token EQUAL
%token FALSE
%token FUN
%token IF
%token IN
%token INT
%token <int> INTLITERAL
%token JOIN
%token LCURLY
%token LET
%token LESSEQ
%token LPAREN
%token LSQUARE
%token MEET
%token <string> QLITERAL
%token QUESTION
%token <string> QVAR
%token RCURLY
%token RPAREN
%token RSQUARE
%token THEN
%token TOP
%token TRUE
%token <string> TVAR
%token <string> VAR

%right ARROW
%left  MEET JOIN
%nonassoc QUALIFY

%type <unit> query
%start query


%%
query:
  EOL {}
| exp QUESTION tschema EOL {
    
    let (e, t) = ($1, $3) in
      Printf.printf ">> ";
      if check_type e t then
	Printf.printf "true"
      else
	Printf.printf "false"
      ;
      Printf.printf "\n\n";
      flush stdout

  }
| QUESTION exp EOL {

    let e = $2 in
      Printf.printf(">> ");
      begin try
	let t = infer_type e in
	  Printf.printf "%s" (pprint_type t)
      with _ ->
	Printf.printf "Cannot infer type"
      end;
      Printf.printf "\n\n";
      flush stdout
  }
| BANG exp EOL {
    let e = $2 in
      Printf.printf(">> Graph:\n");
      let graph = expr_qualgraph e in
	FlowGraphPrinter.output_graph stdout graph;
      Printf.printf("\n<< EOG\n\n");
      flush stdout
  }
	
;

tschema:
  TVAR DOT tschema { ForallTyp($1, $3) }
| qschema { $1 }
;

qschema:
  QVAR LESSEQ qualliteral DOT qschema { ForallQual($1, $3, $5) }
| mtype { $1 }
;

mtype:
  qual mtype %prec QUALIFY {
    match $2 with
	Int(_) -> Int($1)
      | Bool(_) -> Bool($1)
      | TyVar(_, a) -> TyVar($1, a)
      | Arrow(_, t1, t2) -> Arrow($1, t1, t2)
      | Nil -> Nil
      | t -> t
  }
| mtype ARROW mtype { Arrow(Top, $1, $3) }
| INT { Int(Top) }
| BOOL { Bool(Top) }
| TVAR { TyVar(Top, $1) }
| LPAREN mtype RPAREN { $2 }
;

qual:
  qual JOIN qual { QualJoin($1, $3) }
| qual MEET qual { QualMeet($1, $3) }
| QVAR { QualVar($1) }
| qualliteral { $1 }
| LPAREN qual RPAREN { $2 }
;

qualliteral:
  TOP { Top }
| BOTTOM { Bottom }
| QLITERAL { Qual($1) }
;


exp:
  LPAREN exp RPAREN { $2 }
| TRUE { True }
| FALSE { False }
| VAR { Var($1) }
| INTLITERAL { Num($1) }
| IF exp THEN exp ELSE exp { If($2, $4, $6) }
| LET VAR COLON tschema EQUAL exp IN exp { Let($2, Some $4, $6, $8) }
| LET VAR EQUAL exp IN exp { Let($2, None, $4, $6) }
| FUN VAR COLON mtype EQUAL exp { Abs($2, Some $4, $6) }
| FUN VAR EQUAL exp { Abs($2, None, $4) }
| TVAR DOT exp { TyAbs($1, $3) }
| QVAR LESSEQ qualliteral DOT exp { QualAbs($1, $3, $5) }
| LCURLY LSQUARE qual RSQUARE RCURLY exp { Annot($3, $6) }
| exp LSQUARE mtype RSQUARE { TyApp($1, $3) }
| exp LCURLY qualliteral RCURLY { QualApp($1, $3) }
| exp exp { App($1, $2) }
%%
