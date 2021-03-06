// Copyright 2012, Google Inc. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

%{
package sqlparser

import "bytes"

func SetParseTree(yylex interface{}, stmt Statement) {
  tn := yylex.(*Tokenizer)
  tn.ParseTree = stmt
}

func SetAllowComments(yylex interface{}, allow bool) {
  tn := yylex.(*Tokenizer)
  tn.AllowComments = allow
}

func ForceEOF(yylex interface{}) {
  tn := yylex.(*Tokenizer)
  tn.ForceEOF = true
}

var (
  LJOIN = []byte("left join")
  RJOIN = []byte("right join")
  CJOIN = []byte("cross join")
  NJOIN = []byte("natural join")
  SHARE = []byte("share")
  MODE =  []byte("mode")
)

%}

%union {
  node        *Node
  statement   Statement
  comments    Comments
  str         []byte
  distinct    Distinct
  selectExprs SelectExprs
  selectExpr  SelectExpr
  columns     Columns
  tableExprs  TableExprs
  tableExpr   TableExpr
  sqlNode     SQLNode
}

%token <node> SELECT INSERT UPDATE DELETE FROM WHERE GROUP HAVING ORDER BY LIMIT COMMENT FOR
%token <node> ALL DISTINCT AS EXISTS IN IS LIKE BETWEEN NULL ASC DESC VALUES INTO DUPLICATE KEY DEFAULT SET LOCK
%token <node> ID STRING NUMBER VALUE_ARG
%token <node> LE GE NE NULL_SAFE_EQUAL
%token <node> LEX_ERROR
%token <node> '(' '=' '<' '>' '~'

%left <node> UNION MINUS EXCEPT INTERSECT
%left <node> ','
%left <node> JOIN STRAIGHT_JOIN LEFT RIGHT INNER OUTER CROSS NATURAL USE FORCE
%left <node> ON
%left <node> AND OR
%right <node> NOT
%left <node> '&' '|' '^'
%left <node> '+' '-'
%left <node> '*' '/' '%'
%nonassoc <node> '.'
%left <node> UNARY
%right <node> CASE, WHEN, THEN, ELSE
%left <node> END

// DDL Tokens
%token <node> CREATE ALTER DROP RENAME
%token <node> TABLE INDEX VIEW TO IGNORE IF UNIQUE USING

%start any_command

// Fake Tokens
%token <node> NODE_LIST UPLUS UMINUS CASE_WHEN WHEN_LIST FUNCTION NO_LOCK FOR_UPDATE LOCK_IN_SHARE_MODE
%token <node> NOT_IN NOT_LIKE NOT_BETWEEN IS_NULL IS_NOT_NULL UNION_ALL INDEX_LIST TABLE_EXPR

%type <statement> command
%type <statement> select_statement insert_statement update_statement delete_statement set_statement
%type <statement> create_statement alter_statement rename_statement drop_statement
%type <comments> comment_opt comment_list
%type <str> union_op
%type <distinct> distinct_opt
%type <selectExprs> select_expression_list
%type <selectExpr> select_expression
%type <str> as_lower_opt as_opt
%type <node> expression
%type <tableExprs> table_expression_list
%type <tableExpr> table_expression
%type <str> join_type
%type <node> simple_table_expression dml_table_expression index_hint_list
%type <node> where_expression_opt boolean_expression condition compare
%type <sqlNode> values
%type <node> parenthesised_lists parenthesised_list value_expression_list value_expression keyword_as_func
%type <node> unary_operator case_expression when_expression_list when_expression column_name value
%type <node> group_by_opt having_opt order_by_opt order_list order asc_desc_opt limit_opt lock_opt on_dup_opt
%type <columns> column_list_opt column_list
%type <node> index_list update_list update_expression
%type <node> exists_opt not_exists_opt ignore_opt non_rename_operation to_opt constraint_opt using_opt
%type <node> sql_id
%type <node> force_eof

%%

any_command:
  command
  {
    SetParseTree(yylex, $1)
  }

command:
  select_statement
| insert_statement
| update_statement
| delete_statement
| set_statement
| create_statement
| alter_statement
| rename_statement
| drop_statement

select_statement:
  SELECT comment_opt distinct_opt select_expression_list FROM table_expression_list where_expression_opt group_by_opt having_opt order_by_opt limit_opt lock_opt
  {
    $$ = &Select{Comments: $2, Distinct: $3, SelectExprs: $4, From: $6, Where: $7, GroupBy: $8, Having: $9, OrderBy: $10, Limit: $11, Lock: $12}
  }
| select_statement union_op select_statement %prec UNION
  {
    $$ = &Union{Type: $2, Select1: $1.(SelectStatement), Select2: $3.(SelectStatement)}
  }

insert_statement:
  INSERT comment_opt INTO dml_table_expression column_list_opt values on_dup_opt
  {
    $$ = &Insert{Comments: $2, Table: $4, Columns: $5, Values: $6, OnDup: $7}
  }

update_statement:
  UPDATE comment_opt dml_table_expression SET update_list where_expression_opt order_by_opt limit_opt
  {
    $$ = &Update{Comments: $2, Table: $3, List: $5, Where: $6, OrderBy: $7, Limit: $8}
  }

delete_statement:
  DELETE comment_opt FROM dml_table_expression where_expression_opt order_by_opt limit_opt
  {
    $$ = &Delete{Comments: $2, Table: $4, Where: $5, OrderBy: $6, Limit: $7}
  }

set_statement:
  SET comment_opt update_list
  {
    $$ = &Set{Comments: $2, Updates: $3}
  }

create_statement:
  CREATE TABLE not_exists_opt ID force_eof
  {
    $$ = &DDLSimple{Action: CREATE, Table: $4}
  }
| CREATE constraint_opt INDEX sql_id using_opt ON ID force_eof
  {
    // Change this to an alter statement
    $$ = &DDLSimple{Action: ALTER, Table: $7}
  }
| CREATE VIEW sql_id force_eof
  {
    $$ = &DDLSimple{Action: CREATE, Table: $3}
  }

alter_statement:
  ALTER ignore_opt TABLE ID non_rename_operation force_eof
  {
    $$ = &DDLSimple{Action: ALTER, Table: $4}
  }
| ALTER ignore_opt TABLE ID RENAME to_opt ID
  {
    // Change this to a rename statement
    $$ = &Rename{OldName: $4, NewName: $7}
  }
| ALTER VIEW sql_id force_eof
  {
    $$ = &DDLSimple{Action: ALTER, Table: $3}
  }

rename_statement:
  RENAME TABLE ID TO ID
  {
    $$ = &Rename{OldName: $3, NewName: $5}
  }

drop_statement:
  DROP TABLE exists_opt ID
  {
    $$ = &DDLSimple{Action: DROP, Table: $4}
  }
| DROP INDEX sql_id ON ID
  {
    // Change this to an alter statement
    $$ = &DDLSimple{Action: ALTER, Table: $5}
  }
| DROP VIEW exists_opt sql_id force_eof
  {
    $$ = &DDLSimple{Action: DROP, Table: $4}
  }

comment_opt:
  {
    SetAllowComments(yylex, true)
  }
  comment_list
  {
    $$ = $2
    SetAllowComments(yylex, false)
  }

comment_list:
  {
    $$ = nil
  }
| comment_list COMMENT
  {
    $$ = append($$, Comment($2.Value))
  }

union_op:
  UNION
  {
    $$ = $1.Value
  }
| UNION ALL
  {
    $$ = []byte("union all")
  }
| MINUS
  {
    $$ = $1.Value
  }
| EXCEPT
  {
    $$ = $1.Value
  }
| INTERSECT
  {
    $$ = $1.Value
  }

distinct_opt:
  {
    $$ = Distinct(false)
  }
| DISTINCT
  {
    $$ = Distinct(true)
  }

select_expression_list:
  select_expression
  {
    $$ = SelectExprs{$1}
  }
| select_expression_list ',' select_expression
  {
    $$ = append($$, $3)
  }

select_expression:
  '*'
  {
    $$ = &StarExpr{}
  }
| expression as_lower_opt
  {
    $$ = &NonStarExpr{Expr: $1, As: $2}
  }
| ID '.' '*'
  {
    $$ = &StarExpr{TableName: $1.Value}
  }

expression:
  boolean_expression
| value_expression

as_lower_opt:
  {
    $$ = nil
  }
| sql_id
  {
    $$ = $1.Value
  }
| AS sql_id
  {
    $$ = $2.Value
  }

table_expression_list:
  table_expression
  {
    $$ = TableExprs{$1}
  }
| table_expression_list ',' table_expression
  {
    $$ = append($$, $3)
  }

table_expression:
  simple_table_expression as_opt index_hint_list
  {
    $$ = &AliasedTableExpr{Expr:$1, As: $2, Hint: $3}
  }
| '(' table_expression ')'
  {
    $$ = &ParenTableExpr{Inner: $2}
  }
| table_expression join_type table_expression %prec JOIN
  {
    $$ = &JoinTableExpr{
      LeftExpr:  $1,
      Join:      $2,
      RightExpr: $3,
    }
  }
| table_expression join_type table_expression ON boolean_expression %prec JOIN
  {
    $$ = &JoinTableExpr{
      LeftExpr:  $1,
      Join:      $2,
      RightExpr: $3,
      On:        $5,
    }
  }

as_opt:
  {
    $$ = nil
  }
| ID
  {
    $$ = $1.Value
  }
| AS ID
  {
    $$ = $2.Value
  }

join_type:
  JOIN
  {
    $$ = $1.Value
  }
| STRAIGHT_JOIN
  {
    $$ = $1.Value
  }
| LEFT JOIN
  {
    $$ = LJOIN
  }
| LEFT OUTER JOIN
  {
    $$ = LJOIN
  }
| RIGHT JOIN
  {
    $$ = RJOIN
  }
| RIGHT OUTER JOIN
  {
    $$ = RJOIN
  }
| INNER JOIN
  {
    $$ = $2.Value
  }
| CROSS JOIN
  {
    $$ = CJOIN
  }
| NATURAL JOIN
  {
    $$ = NJOIN
  }

simple_table_expression:
ID
| ID '.' ID
  {
    $$ = $2.PushTwo($1, $3)
  }
| '(' select_statement ')'
  {
    $$ = $1.Push($2)
  }

dml_table_expression:
ID
| ID '.' ID
  {
    $$ = $2.PushTwo($1, $3)
  }

index_hint_list:
  {
    $$ = nil
  }
| USE INDEX '(' index_list ')'
  {
    $$.Push($4)
  }
| FORCE INDEX '(' index_list ')'
  {
    $$.Push($4)
  }

where_expression_opt:
  {
    $$ = NewSimpleParseNode(WHERE, "where")
  }
| WHERE boolean_expression
  {
    $$ = $1.Push($2)
  }

boolean_expression:
  condition
| boolean_expression AND boolean_expression
  {
    $$ = $2.PushTwo($1, $3)
  }
| boolean_expression OR boolean_expression
  {
    $$ = $2.PushTwo($1, $3)
  }
| NOT boolean_expression
  {
    $$ = $1.Push($2)
  }
| '(' boolean_expression ')'
  {
    $$ = $1.Push($2)
  }

condition:
  value_expression compare value_expression
  {
    $$ = $2.PushTwo($1, $3)
  }
| value_expression IN parenthesised_list
  {
    $$ = $2.PushTwo($1, $3)
  }
| value_expression NOT IN parenthesised_list
  {
    $$ = NewSimpleParseNode(NOT_IN, "not in").PushTwo($1, $4)
  }
| value_expression LIKE value_expression
  {
    $$ = $2.PushTwo($1, $3)
  }
| value_expression NOT LIKE value_expression
  {
    $$ = NewSimpleParseNode(NOT_LIKE, "not like").PushTwo($1, $4)
  }
| value_expression BETWEEN value_expression AND value_expression
  {
    $$ = $2
    $$.Push($1)
    $$.Push($3)
    $$.Push($5)
  }
| value_expression NOT BETWEEN value_expression AND value_expression
  {
    $$ = NewSimpleParseNode(NOT_BETWEEN, "not between")
    $$.Push($1)
    $$.Push($4)
    $$.Push($6)
  }
| value_expression IS NULL
  {
    $$ = NewSimpleParseNode(IS_NULL, "is null").Push($1)
  }
| value_expression IS NOT NULL
  {
    $$ = NewSimpleParseNode(IS_NOT_NULL, "is not null").Push($1)
  }
| EXISTS '(' select_statement ')'
  {
    $$ = $1.Push($3)
  }

compare:
  '='
| '<'
| '>'
| LE
| GE
| NE
| NULL_SAFE_EQUAL

values:
  VALUES parenthesised_lists
  {
    $$ = $1.Push($2)
  }
| select_statement
  {
    $$ = $1
  }

parenthesised_lists:
  parenthesised_list
  {
    $$ = NewSimpleParseNode(NODE_LIST, "node_list")
    $$.Push($1)
  }
| parenthesised_lists ',' parenthesised_list
  {
    $$.Push($3)
  }

parenthesised_list:
  '(' value_expression_list ')'
  {
    $$ = $1.Push($2)
  }
| '(' select_statement ')'
  {
    $$ = $1.Push($2)
  }

value_expression_list:
  value_expression
  {
    $$ = NewSimpleParseNode(NODE_LIST, "node_list")
    $$.Push($1)
  }
| value_expression_list ',' value_expression
  {
    $$.Push($3)
  }

value_expression:
  value
| column_name
| '(' select_statement ')'
  {
    $$ = $1.Push($2)
  }
| '(' value_expression_list ')'
  {
    if $2.Len() == 1 {
      $2 = $2.NodeAt(0)
    }
    switch $2.Type {
    case NUMBER, STRING, ID, VALUE_ARG, '(', '.':
      $$ = $2
    default:
      $$ = $1.Push($2)
    }
  }
| value_expression '&' value_expression
  {
    $$ = $2.PushTwo($1, $3)
  }
| value_expression '|' value_expression
  {
    $$ = $2.PushTwo($1, $3)
  }
| value_expression '^' value_expression
  {
    $$ = $2.PushTwo($1, $3)
  }
| value_expression '+' value_expression
  {
    $$ = $2.PushTwo($1, $3)
  }
| value_expression '-' value_expression
  {
    $$ = $2.PushTwo($1, $3)
  }
| value_expression '*' value_expression
  {
    $$ = $2.PushTwo($1, $3)
  }
| value_expression '/' value_expression
  {
    $$ = $2.PushTwo($1, $3)
  }
| value_expression '%' value_expression
  {
    $$ = $2.PushTwo($1, $3)
  }
| unary_operator value_expression %prec UNARY
  {
    if $2.Type == NUMBER { // Simplify trivial unary expressions
      switch $1.Type {
      case UMINUS:
        $2.Value = append($1.Value, $2.Value...)
        $$ = $2
      case UPLUS:
        $$ = $2
      default:
        $$ = $1.Push($2)
      }
    } else {
      $$ = $1.Push($2)
    }
  }
| sql_id '(' ')'
  {
    $1.Type = FUNCTION
    $$ = $1.Push(NewSimpleParseNode(NODE_LIST, "node_list"))
  }
| sql_id '(' select_expression_list ')'
  {
    $1.Type = FUNCTION
    $$ = $1.Push($3)
  }
| sql_id '(' DISTINCT select_expression_list ')'
  {
    $1.Type = FUNCTION
    $$ = $1.Push($3)
    $$ = $1.Push($4)
  }
| keyword_as_func '(' select_expression_list ')'
  {
    $1.Type = FUNCTION
    $$ = $1.Push($3)
  }
| case_expression

keyword_as_func:
  IF
| VALUES

unary_operator:
  '+'
  {
    $$ = NewSimpleParseNode(UPLUS, "+")
  }
| '-'
  {
    $$ = NewSimpleParseNode(UMINUS, "-")
  }
| '~'

case_expression:
  CASE when_expression_list END
  {
    $$ = NewSimpleParseNode(CASE_WHEN, "case")
    $$.Push($2)
  }
| CASE expression when_expression_list END
  {
    $$.PushTwo($2, $3)
  }

when_expression_list:
  when_expression
  {
    $$ = NewSimpleParseNode(WHEN_LIST, "when_list")
    $$.Push($1)
  }
| when_expression_list when_expression
  {
    $$.Push($2)
  }

when_expression:
  WHEN expression THEN expression
  {
    $$.PushTwo($2, $4)
  }
| ELSE expression
  {
    $$.Push($2)
  }

column_name:
  sql_id
| ID '.' sql_id
  {
    $$ = $2.PushTwo($1, $3)
  }

value:
  STRING
| NUMBER
| VALUE_ARG
| NULL

group_by_opt:
  {
    $$ = NewSimpleParseNode(GROUP, "group")
  }
| GROUP BY value_expression_list
  {
    $$ = $1.Push($3)
  }

having_opt:
  {
    $$ = NewSimpleParseNode(HAVING, "having")
  }
| HAVING boolean_expression
  {
    $$ = $1.Push($2)
  }

order_by_opt:
  {
    $$ = NewSimpleParseNode(ORDER, "order")
  }
| ORDER BY order_list
  {
    $$ = $1.Push($3)
  }

order_list:
  order
  {
    $$ = NewSimpleParseNode(NODE_LIST, "node_list")
    $$.Push($1)
  }
| order_list ',' order
  {
    $$ = $1.Push($3)
  }

order:
  value_expression asc_desc_opt
  {
    $$ = $2.Push($1)
  }

asc_desc_opt:
  {
    $$ = NewSimpleParseNode(ASC, "asc")
  }
| ASC
| DESC

limit_opt:
  {
    $$ = NewSimpleParseNode(LIMIT, "limit")
  }
| LIMIT value_expression
  {
    $$ = $1.Push($2)
  }
| LIMIT value_expression ',' value_expression
  {
    $$ = $1.PushTwo($2, $4)
  }

lock_opt:
  {
    $$ = NewSimpleParseNode(NO_LOCK, "")
  }
| FOR UPDATE
  {
    $$ = NewSimpleParseNode(FOR_UPDATE, " for update")
  }
| LOCK IN sql_id sql_id
  {
    if !bytes.Equal($3.Value, SHARE) {
      yylex.Error("expecting share")
      return 1
    }
    if !bytes.Equal($4.Value, MODE) {
      yylex.Error("expecting mode")
      return 1
    }
    $$ = NewSimpleParseNode(LOCK_IN_SHARE_MODE, " lock in share mode")
  }

column_list_opt:
  {
    $$ = nil
  }
| '(' column_list ')'
  {
    $$ = $2
  }

column_list:
  column_name
  {
    $$ = Columns{&NonStarExpr{Expr: $1}}
  }
| column_list ',' column_name
  {
    $$ = append($$, &NonStarExpr{Expr: $3})
  }

index_list:
  sql_id
  {
    $$ = NewSimpleParseNode(INDEX_LIST, "")
    $$.Push($1)
  }
| index_list ',' sql_id
  {
    $$ = $1.Push($3)
  }

on_dup_opt:
  {
    $$ = NewSimpleParseNode(DUPLICATE, "duplicate")
  }
| ON DUPLICATE KEY UPDATE update_list
  {
    $$ = $2.Push($5)
  }

update_list:
  update_expression
  {
    $$ = NewSimpleParseNode(NODE_LIST, "node_list")
    $$.Push($1)
  }
| update_list ',' update_expression
  {
    $$ = $1.Push($3)
  }

update_expression:
  column_name '=' expression
  {
    $$ = $2.PushTwo($1, $3)
  }

exists_opt:
  { $$ = nil }
| IF EXISTS

not_exists_opt:
  { $$ = nil }
| IF NOT EXISTS

ignore_opt:
  { $$ = nil }
| IGNORE

non_rename_operation:
  ALTER
| DEFAULT
| DROP
| ORDER
| ID

to_opt:
  { $$ = nil }
| TO

constraint_opt:
  { $$ = nil }
| UNIQUE

using_opt:
  { $$ = nil }
| USING sql_id

sql_id:
  ID
  {
    $$.LowerCase()
  }

force_eof:
{
  ForceEOF(yylex)
}
