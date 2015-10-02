------------------------------------------------------------------------------
--                                                                          --
--                            GNAT2WHY COMPONENTS                           --
--                                                                          --
--              F L O W . C O N T R O L _ F L O W _ G R A P H               --
--                                                                          --
--                                 B o d y                                  --
--                                                                          --
--               Copyright (C) 2013-2015, Altran UK Limited                 --
--                                                                          --
-- gnat2why is  free  software;  you can redistribute  it and/or  modify it --
-- under terms of the  GNU General Public License as published  by the Free --
-- Software  Foundation;  either version 3,  or (at your option)  any later --
-- version.  gnat2why is distributed  in the hope that  it will be  useful, --
-- but WITHOUT ANY WARRANTY; without even the implied warranty of  MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for  more details.  You should have  received  a copy of the GNU --
-- General  Public License  distributed with  gnat2why;  see file COPYING3. --
-- If not,  go to  http://www.gnu.org/licenses  for a complete  copy of the --
-- license.                                                                 --
--                                                                          --
------------------------------------------------------------------------------

with Ada.Containers.Doubly_Linked_Lists;

with Elists;                             use Elists;
with Errout;
with Namet;                              use Namet;
with Nlists;                             use Nlists;
with Opt;                                use Opt;
with Sem_Aux;                            use Sem_Aux;
with Sem_Ch12;                           use Sem_Ch12;
with Sem_Eval;                           use Sem_Eval;
with Sem_Prag;                           use Sem_Prag;
with Sem_Util;                           use Sem_Util;
with Sinfo;                              use Sinfo;
with Snames;                             use Snames;
with Stand;                              use Stand;
with Treepr;                             use Treepr;
with Uintp;                              use Uintp;

with Hashing;                            use Hashing;
with SPARK_Definition;                   use SPARK_Definition;
with SPARK_Util;                         use SPARK_Util;

with Flow_Classwide;                     use Flow_Classwide;
with Flow.Control_Flow_Graph.Utility;    use Flow.Control_Flow_Graph.Utility;
with Flow_Debug;                         use Flow_Debug;
with Flow_Error_Messages;                use Flow_Error_Messages;
with Flow_Utility.Initialization;        use Flow_Utility.Initialization;
with Flow_Utility;                       use Flow_Utility;

with VC_Kinds;                           use VC_Kinds;
with Why;

pragma Unreferenced (Flow_Debug);

--  Documentation on how we deal with some non-obvious constructs.
--
--  Note: This is a new section and thus somewhat incomplete, but the idea
--  is to document any new, non-obvious decisions here.
--
--  Dynamic_Predicate
--  =================
--  The front-end translates this into a special function which is then
--  implicitly called. We need to check two things: we do not use variables
--  in the predicate, and explicit membership should have the constants
--  with variable inputs used in the predicate appear.
--
--  We currently ignore any proof-flow for the dynamic predicate; and the
--  member ship effects are introduces as follows:
--  * only in phase 1, get_function_set will add calls to the predicates for
--    membership tests
--  * in phase 1, we generate normal globals for the predicate functions
--  * in phase 2, we add the global effects of predicates in get_variable_set
--    for membership tests
--  * in phase 2 sanity checking, we examine the global variables of the
--    predicate functions

package body Flow.Control_Flow_Graph is

   use type Ada.Containers.Count_Type;

   use type Flow_Graphs.Vertex_Id;

   use Vertex_Sets;
   use type Flow_Id_Sets.Set;
   use type Node_Sets.Set;

   package Union_Lists is new Ada.Containers.Doubly_Linked_Lists
     (Element_Type => Union_Id,
      "="          => "=");

   ------------------------------------------------------------
   --  Local types
   ------------------------------------------------------------

   subtype Nodes_Ignored_By_Process_Statement is Node_Kind
     with Static_Predicate => Nodes_Ignored_By_Process_Statement in
                                N_Abstract_Subprogram_Declaration |
                                N_Freeze_Entity                   |
                                N_Freeze_Generic_Entity           |
                                N_Generic_Instantiation           |
                                N_Generic_Package_Declaration     |
                                N_Generic_Subprogram_Declaration  |
                                N_Implicit_Label_Declaration      |
                                N_Incomplete_Type_Declaration     |
                                N_Itype_Reference                 |
                                N_Label                           |
                                N_Number_Declaration              |
                                N_Object_Renaming_Declaration     |
                                N_Package_Renaming_Declaration    |
                                N_Private_Type_Declaration        |
                                N_Protected_Body                  |
                                N_Protected_Body_Stub             |
                                N_Protected_Type_Declaration      |
                                N_Representation_Clause           |
                                N_Subprogram_Body                 |
                                N_Subprogram_Body_Stub            |
                                N_Subprogram_Declaration          |
                                N_Subprogram_Renaming_Declaration |
                                N_Task_Body                       |
                                N_Task_Body_Stub                  |
                                N_Task_Type_Declaration           |
                                N_Use_Package_Clause              |
                                N_Use_Type_Clause                 |
                                N_Validate_Unchecked_Conversion;

   ---------------------
   -- Connection_Maps --
   ---------------------

   --  The flow graph is produced using two datastructures,
   --  Graph_Connections and a map Union_Id -> Graph_Connections.
   --
   --  Any node in the AST may be represented by some vertices in the flow
   --  graph. For example if N is a N_Subprogram_Body and its
   --  Handled_Statement_Sequence contains the following statement:
   --
   --     if X > 0 then
   --        X := X - 1;
   --     else
   --        X := 0;
   --     end if;
   --
   --  Lets start at the bottom. We recurse down the tree and at some point
   --  we will call Do_Assignment_Statement for each of the two
   --  assignments. Every Do_FOOBAR procedure takes a FOOBAR node, and
   --  fills in the connection map for that node.
   --
   --  So, for the first assinment statement (assume this node is Ass_1 in
   --  the AST) we create a vertex (but no edges!) in the flow graph. We
   --  also create an entry in the connection map from Ass_1 to a
   --  connection map with the trivial "unit" connection.
   --
   --        GRAPH            CM
   --    0. [X := X - 1]      Ass_1 -> (0, {0})
   --
   --  (Where "0." is the vertex id of the node for "X := X - 1".) Each
   --  connection map captures a single entry vertex (0 in our example) and
   --  a set of exit vertices ({0} in our example). Read this as "control
   --  flow for the node Ass_1 is as follows: control goes into this vertex
   --  (0) we do one thing and control leaves this node again (0)".
   --
   --  Lets process the second assignment statement, our graph and
   --  connection map now looks like this:
   --
   --        GRAPH            CM
   --    0. [X := X - 1]      Ass_1 -> (0, {0})
   --    1. [X := 0]          Ass_2 -> (1, {1})
   --
   --  We now go up the tree and look at Do_If_Statement. First produce a
   --  vertex (it will be number "2".) in the graph for the N_If_Statement
   --  itself. We then assemble the connection map as follows:
   --
   --     - The entry point for the if statement is obviously the if
   --       statement itself (i.e. 2)
   --
   --     - We have two ways we can exit from the if statement S: we can
   --       fall off the end of the if branch (Then_Statements (S)) or the
   --       else branch (Else_Statements (S)). So the exits for the if
   --       statement X is the union of all exits of all branches.
   --
   --       To determine the exit of one of our branch we simply look into
   --       the connection map what is recorded for Then_Statements (S) and
   --       Else_Statements (S). In our case we get Ass_1 and Ass_2, but in
   --       real life you'd get some kind of List_Id.
   --
   --  So now our picture looks like this:
   --
   --        GRAPH            CM
   --    0. [X := X - 1]      Ass_1 -> (0, {0})
   --    1. [X := 0]          Ass_2 -> (1, {1})
   --    2. [if X > 0]        S     -> (2, {0, 1})
   --
   --  But wait, we still have not added any edges to the flow graph. We
   --  need to make sure that we have an edge from vertex 2 to entry of the
   --  Then_Statements (S) and an edge to the Else_Statements (S). The
   --  Do_If_Statement procedure will also call one of the Linkup
   --  procedures. These take essentially two argumens: A group of "from"
   --  points and a single target point and create edges from all "from" to
   --  the "to".
   --
   --  So, we will call:
   --     Linkup (2, connection_map[then_statements (s)].standard_entry)
   --     Linkup (2, connection_map[else_statements (s)].standard_entry)
   --
   --  And now our graph and connection map looks like this:
   --
   --        GRAPH                          CM
   --            2. [if X > 0]              Ass_1 -> (0, {0})
   --                /      \               Ass_2 -> (1, {1})
   --               /        \              S     -> (2, {0, 1})
   --              /          \
   --  0. [X := X - 1]     1. [X := 0]
   --
   --  Notice how the connection map was not changed by Linkup, but only
   --  the graph. The connection map for node N can be considered to be a
   --  "summary for node N and all child nodes".

   type Graph_Connections is record
      Standard_Entry : Flow_Graphs.Vertex_Id;
      Standard_Exits : Vertex_Sets.Set;
   end record;

   No_Connections : constant Graph_Connections :=
     Graph_Connections'(Standard_Entry => Flow_Graphs.Null_Vertex,
                        Standard_Exits => Vertex_Sets.Empty_Set);

   function Trivial_Connection (V : Flow_Graphs.Vertex_Id)
                               return Graph_Connections
   is (Graph_Connections'(Standard_Entry => V,
                          Standard_Exits => Vertex_Sets.To_Set (V)));
   --  Produce the trivial connection.

   function Union_Hash (X : Union_Id) return Ada.Containers.Hash_Type
   is (Generic_Integer_Hash (Integer (X)));

   package Connection_Maps is new Ada.Containers.Hashed_Maps
     (Key_Type        => Union_Id,
      Element_Type    => Graph_Connections,
      Hash            => Union_Hash,
      Equivalent_Keys => "=",
      "="             => "=");

   procedure Copy_Connections (CM  : in out Connection_Maps.Map;
                               Dst : Union_Id;
                               Src : Union_Id);
   --  Creates the connection map for Dst and copies all fields from Src to
   --  it.

   -------------
   -- Context --
   -------------

   --  The context is a bag of extra state that is passed around through
   --  each Do_* procedure.
   --
   --  Perhaps the most important aspect of the Context is the
   --  Folded_Function_Checks map, which is used to keep track of functions
   --  with dependency relations. The only reason to put a dependency
   --  relation on a function is to note that not all parameters have been
   --  used. For example:
   --
   --     function Multiply_After_Delay (A, B : Integer;
   --                                    W    : Float)
   --                                    return Integer
   --     with Depends => (Multiply_After_Delay'Result => (A, B),
   --                      null                        => W);
   --
   --  If such a function is used, we do not want W to flow into the final
   --  result of whatever it is doing, however, this is difficult as
   --  functions are not really processed separately. Instead we are just
   --  interested in the "set of variables" present in an expression. So
   --  instead we have a parameter in Get_Variable_Set (Fold_Functions)
   --  which, if specified, will return simply the set {A, B} instead of
   --  {A, B, W} for expressions involving calls to Multiply_After_Delay.
   --
   --  However, we need to make sure that all variables are initialized
   --  when we call our function; but the generated vertex for an
   --  expression involving it no longer features W.
   --
   --  Hence, in all places where we call Get_Variable_Set and fold
   --  functions, we also remember the node_id of the expression. For
   --  example, if we have an if statement:
   --
   --     if Multiply_After_Delay (X, Y, Z) = 0 then
   --        ...
   --
   --  Lets assume the node_id for the statement is 42, and the node_id for
   --  Condition (42) is 88. When we process Get_Variable_Set (88), we
   --  place the following into the Folded_Function_Checks map:
   --
   --     42 -> {88}
   --
   --  At the end of Process_Statement we then re-check each of these
   --  expression and emit a sink vertex in front of the original vertex to
   --  check only the "unused" variables.
   --
   --  Inspect the graphs generated for test M412-008 for more information.
   --
   --  Finally we take a note of all vertices that are linked directly
   --  to the Helper_End_Vertex because they belong to a non-returning
   --  procedure. Vertices of this kind that lie within dead code will
   --  have to be unlinked at the end.

   type Context is record
      Current_Loops          : Node_Sets.Set;
      --  The set of loops currently processed. The innermost loop
      --  currently processed is Active_Loop.

      Active_Loop            : Entity_Id;
      --  The currently processed loop. This is always a member of
      --  Current_Loops, unless no loop is currently processed.

      Entry_References       : Node_Graphs.Map;
      --  A map from loops -> 'loop_entry references.

      Folded_Function_Checks : Node_Graphs.Map;
      --  A set of nodes we need to separately check for uninitialized
      --  variables due to function folding.
   end record;

   No_Context : constant Context :=
     Context'(Current_Loops          => Node_Sets.Empty_Set,
              Active_Loop            => Empty,
              Entry_References       => Node_Graphs.Empty_Map,
              Folded_Function_Checks => Node_Graphs.Empty_Map);

   ------------------------------------------------------------
   --  Local declarations
   ------------------------------------------------------------

   procedure Add_Vertex (FA : in out Flow_Analysis_Graphs;
                         F  : Flow_Id;
                         A  : V_Attributes);
   --  Helper procedure to add a vertex (with attributes) to the graph.

   procedure Add_Vertex (FA : in out Flow_Analysis_Graphs;
                         F  : Flow_Id;
                         A  : V_Attributes;
                         V  : out Flow_Graphs.Vertex_Id);
   --  Helper procedure to add a vertex (with attributes) to the graph,
   --  returning the Id of the newly added vertex.

   procedure Add_Vertex (FA : in out Flow_Analysis_Graphs;
                         A  : V_Attributes;
                         V  : out Flow_Graphs.Vertex_Id);
   --  Helper procedure to add an unkeyed vertex (with attributes) to the
   --  graph, returning its Id.

   procedure Linkup
     (FA    : in out Flow_Analysis_Graphs;
      Froms : Vertex_Sets.Set;
      To    : Flow_Graphs.Vertex_Id)
      with Pre => To /= Flow_Graphs.Null_Vertex;
   --  Link all vertices in Froms to the To vertex in the given graph.

   procedure Linkup
     (FA    : in out Flow_Analysis_Graphs;
      From  : Flow_Graphs.Vertex_Id;
      To    : Flow_Graphs.Vertex_Id)
      with Pre => From /= Flow_Graphs.Null_Vertex and then
                  To   /= Flow_Graphs.Null_Vertex;
   --  Link the From to the To vertex in the given graph.

   procedure Join
     (FA    : in out Flow_Analysis_Graphs;
      CM    : in out Connection_Maps.Map;
      Nodes : Union_Lists.List;
      Block : out Graph_Connections);
   --  Join up the standard entry and standard exits of the given
   --  nodes. Block contains the combined standard entry and exits of
   --  the joined up sequence.

   procedure Create_Record_Tree
     (F        : Flow_Id;
      Leaf_Atr : V_Attributes;
      FA       : in out Flow_Analysis_Graphs);
   --  Create part of the tree structure used to represent records. In
   --  particular, we create the subtree which is formed by the leaf F
   --  up to the entire variable represented by F. In the art below
   --  the vertices marked with a * are created by this procedure if F
   --  is R.A.Y. If we come to a vertex which already exists, we
   --  stop. This means calling this procedure once for each leaf will
   --  eventually result in the entire tree.
   --
   --                  R*
   --                 / \
   --                /   \
   --             R.A*    R.B
   --            /   \
   --           /     \
   --      R.A.X       R.A.Y*

   type Var_Kind is (Variable_Kind,
                     Parameter_Kind,
                     Discriminant_Kind,
                     Quantified_Variable_Kind);

   procedure Create_Initial_And_Final_Vertices
     (E    : Entity_Id;
      Kind : Var_Kind;
      FA   : in out Flow_Analysis_Graphs);
   --  Create the 'initial and 'final vertices for the given entity
   --  and link them up to the start and end vertices.

   procedure Create_Initial_And_Final_Vertices
     (F             : Flow_Id;
      Mode          : Param_Mode;
      Uninitialized : Boolean;
      FA            : in out Flow_Analysis_Graphs)
   with Pre => F.Kind in Direct_Mapping | Magic_String;
   --  Create the 'initial and 'final vertices for the given global
   --  and link them up to the start and end vertices.

   function Replace_Flow_Ids
     (Of_This   : Entity_Id;
      With_This : Entity_Id;
      The_Set   : Flow_Id_Sets.Set)
      return Flow_Id_Sets.Set;
   --  Returns a flow set that replaces all Flow_Ids of The_Set that
   --  correspond to Of_This with equivalent Flow_Ids that correspond to
   --  With_This.

   procedure Do_Assignment_Statement
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
      with Pre => Nkind (N) = N_Assignment_Statement;
   --  Process assignment statements. Pretty obvious stuff.

   procedure Do_Call_Statement
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
   with Pre => Nkind (N) in N_Procedure_Call_Statement |
                            N_Entry_Call_Statement;
   --  Deal with procedure and entry calls. We follow the ideas of the SDG
   --  paper by Horowitz, Reps and Binkley and have a separate vertex for
   --  each parameter (if a paramater is an in out, we have two vertices
   --  modelling it).
   --
   --  For a procedure P (A : in     Integer;
   --                     B : in out Integer;
   --                     C :    out Integer)
   --  we produce the following CFG when called as P (X, Y, Z):
   --
   --     call P
   --     |
   --     a_in := x
   --     |
   --     b_in := y
   --     |
   --     y := b_out
   --     |
   --     z := c_out
   --
   --  Globals are treated like parameters.
   --
   --  For entries (procedures, functions and entries in protected types)
   --  we also have the protected object as an implicit volatile input
   --  and/or output.
   --
   --  Each of these vertices will also have call_vertex set in its
   --  attributes so that we can fiddle the CDG to look like this:
   --
   --                     call P
   --                    / |  | \
   --           --------/  |  |  ---------
   --          /           /  \           \
   --  a_in := x  b_in := y    y := b_out  z := c_out
   --
   --  Note that dependencies between the parameters are NOT set up
   --  here, this is done in Flow.Interprocedural. The vertex for call
   --  P will have IPFA set or not set, which changes how we fill in
   --  the dependencies. This decision is made in
   --  Control_Flow_Graph.Utility.

   procedure Do_Case_Statement
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
      with Pre => Nkind (N) = N_Case_Statement;
   --  The CFG that we generate for case statements looks like
   --  the following:
   --
   --                       case
   --                      / | | \
   --         ____________/  | |  \________________
   --        /           ___/   \_____             \
   --       /           /             \             \
   --      /            |              |             \
   --    when         when           when   (optional when others)
   --      |            |              |              |
   --      |            |              |              |
   --  when part    when part      when part      when part
   --      |            |              |              |
   --       \            \            /              /
   --        \            \___   ____/              /
   --         \_____________  | |  ________________/
   --                       | | | |
   --
   --  The standard exits of all parts feed into the standard
   --  exits of the entire case statement.

   procedure Do_Delay_Statement
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
   with Pre => Nkind (N) in N_Delay_Until_Statement    |
                            N_Delay_Relative_Statement;
   --  Deal with delay until X statements. We make a vertex where we use all
   --  variables from the expression and we also implicitly use
   --  Ada.Real_Time.Clock_Time.

   procedure Do_Exit_Statement
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
      with Pre => Nkind (N) = N_Exit_Statement;
   --  Deal with loop exit statements. We do this by actually finding
   --  the loop we are associated with and changing the connection map
   --  of that loop and not just our own. This procedure is somewhat
   --  unique as all others Do_XYZ procedures only ever deal with
   --  things pertaining to their given node.

   procedure Do_Extended_Return_Statement
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
      with Pre => Nkind (N) = N_Extended_Return_Statement;
   --  The CFG that we generate for extended return statements looks
   --  like the following:
   --
   --  Returned_Object_Declaration
   --              |
   --  [Handled_Statement_Sequence]
   --              |
   --    return returned_object
   --              |
   --             end
   --
   --  We create a null vertex for the extended return statement (this
   --  vertex is not visible in the CFG).
   --
   --  The "return returned_object" vertex corresponds to the
   --  Return_Statement_Entity of the extended return, and its
   --  Aux_Node is set to the object actually returned (the
   --  N_Defining_Identifier node which has the Is_Return_Object flag
   --  set to True).
   --
   --  The Handled_Statement_Sequence is optional. All exits of the
   --  Handled_Statement_Sequence are gathered in the
   --  "return returned_object" vertex.

   procedure Do_Handled_Sequence_Of_Statements
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
      with Pre => Nkind (N) = N_Handled_Sequence_Of_Statements;
   --  Simply calls Process_Statement_List.

   procedure Do_If_Statement
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
      with Pre => Nkind (N) = N_If_Statement;
   --  Deals with if statements. We generate a CFG which looks like
   --  this:
   --
   --  if
   --  | \
   --  |  if part
   --  |         \-----------------
   --  elsif                       \
   --  |    \                       |
   --  |     elsif part             |
   --  |               \---------   |
   --  elsif                     \  |
   --  |    \                     | |
   --  |     another elsif part   | |
   --  |                       \  | |
   --  (optional else part)     | | |

   procedure Do_Loop_Statement
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
      with Pre  => Nkind (N) = N_Loop_Statement and then
                   Present (Identifier (N)),
           Post => Ctx.Current_Loops.Length = Ctx.Current_Loops'Old.Length;
   --  Deals with all three kinds of loops SPARK supports:
   --
   --     * for loops
   --     * while loops
   --     * (infinite) loops
   --
   --  Refer to the documentation of the nested procedures on how the
   --  constructed CFG will look like.
   --
   --  This will also update the information on variables modified by loops
   --  in Flow_Utility.

   procedure Do_Null_Or_Raise_Statement
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
      with Pre => Nkind (N) in N_Null_Statement
                             | N_Raise_Statement
                             | N_Raise_xxx_Error
                             | N_Exception_Declaration
                             | N_Exception_Renaming_Declaration;
   --  Deals with null and raise statements. We create a new vertex that has
   --  control flow in from the top and leave from the bottom (nothing happens
   --  in between). Exception declarations are treated like null statements.

   procedure Do_Object_Declaration
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
     with Pre => Nkind (N) = N_Object_Declaration;
   --  Deal with declarations (with an optional initialization). We
   --  either generate a null vertex which is then stripped from the
   --  graph or a simple defining vertex. Additionally, if the
   --  object's type has a Default_Initial_Condition aspect, we check
   --  for uninitialized variables in the default initial condition.
   --  This procedure ignores objects that are part of single
   --  concurrent types.

   procedure Do_Package_Body_Or_Stub
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
      with Pre => Nkind (N) in N_Package_Body | N_Package_Body_Stub;
   --  When we find a nested package body, we bring its initializes clause
   --  to bear.
   --
   --  Lets remind ourselves of the example from Do_Package_Declaration:
   --
   --    package Inner
   --      with Abstract_State => (AS1, AS2),
   --           Initializes    => (AS1,
   --                              X => Foo,
   --                              Y => (Foo, Bar),
   --                              Z => Foo)
   --    is
   --       X : Integer := Foo;
   --       Y : Integer := X;
   --    end Inner;
   --
   --  Once we encounter the package body for Inner (or its stub), we know
   --  that the initializes contract has been fulfilled. We produce a
   --  vertex for each part of the initializes clause which models these
   --  dependencies. For the above example we have:
   --
   --    (AS1) | defines      : AS1
   --          | expl_depends : -
   --          | impl_depends : -
   --
   --    (X from Foo) | defines      : X
   --                 | expl_depends : Foo
   --                 | impl_depends : X
   --
   --  Note the implicit self-dependency on X here. We do this to make sure
   --  that the vertex for [x : integer := foo] is not ineffective.
   --
   --    (Y from Foo, Bar) | defines      : Y
   --                      | expl_depends : Foo, Bar
   --                      | impl_depends : Y
   --
   --    (Z from Foo) | defines      : Z
   --                 | expl_depends : Foo
   --                 | impl_depends : -
   --
   --  Note we do not have this self-dependency here, because Z is *not*
   --  initialized at specification.
   --
   --  Finally, we look into the nested package body when the package declares
   --  no state abstractions. This is similar to what we do for the package
   --  spec. Note that we only process the declarations of the package's body
   --  and we only do so if the package's body is actually in SPARK.

   procedure Do_Package_Declaration
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
      with Pre => Nkind (N) = N_Package_Declaration;
   --  When we find a nested package, we add 'initial and 'final
   --  vertices for all variables and state_abstractions it
   --  introduces.
   --
   --  For example, analysis of the following nested package:
   --
   --    package Inner
   --      with Abstract_State => (AS1, AS2),
   --           Initializes    => (AS1,
   --                              X => Foo,
   --                              Y => (Foo, Bar),
   --                              Z => Foo)
   --    is
   --       X : Integer := Foo;
   --       Y : Integer := X;
   --    end Inner;
   --
   --  would have the following effects:
   --
   --    1) Due to the Abstract_State aspect vertices AS1'Initial,
   --       AS1'Final, AS2'Initial and AS2'Final are created.
   --
   --    2) The visible part of package inner is analyzed as if it were
   --       part of the enclosing package. This means initial and final
   --       vertices for x, y, and z are introduced and two vertices for
   --       the two declarations.
   --
   --    3) If the nested package has an initializes aspect then the private
   --       part is ignored. However, if there is no initializes aspect and
   --       if the private part is in SPARK then it is processed.
   --
   --  Note that the initializes aspect is *not* considered yet, as it only
   --  holds once the package body has been elaborated. See
   --  Do_Package_Body_Or_Stub below for more information.

   procedure Do_Pragma
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
      with Pre => Nkind (N) = N_Pragma;
   --  Deals with pragmas. We only check for uninitialized variables. We
   --  do not check for ineffective statements since all pragmas ought to
   --  be ineffective by definition.
   --
   --  We also make a note of any 'Loop_Entry references and store
   --  them in Ctx.Entry_References.
   --
   --  Please also see Pragma_Relevant_To_Flow which decides which
   --  pragmas are important.

   procedure Do_Postcondition
     (Post : Node_Id;
      FA   : in out Flow_Analysis_Graphs;
      CM   : in out Connection_Maps.Map;
      Ctx  : in out Context);
   --  Deals with the given postcondition expression.
   --  ??? can be merged with Do_Precondition

   procedure Do_Precondition
     (Pre : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context);
   --  Deals with the given precondition expression.
   --  ??? can be merged with Do_Postcondition

   procedure Do_Simple_Return_Statement
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
      with Pre => Nkind (N) = N_Simple_Return_Statement;
   --  This deals with return statements (with and without an
   --  expression). They do not have a standard exit, instead we
   --  directly link them to the end vertex.

   procedure Do_Subprogram_Or_Block
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
   with Pre => Nkind (N) in N_Subprogram_Body |
                            N_Task_Body       |
                            N_Block_Statement |
                            N_Package_Body    |
                            N_Entry_Body;
   --  This is the top level procedure which deals with a subprogram,
   --  block or package elaboration statement. The declarations and
   --  sequence of statements is processed and linked.
   --
   --  If we are given an entry body, we also have to deal with the
   --  barrier. We do this by adding a node for the condition with two
   --  paths, one leading to the subprogram and one non-traversable path
   --  (EC_Barrier) skipping it; this is to introduce a control dependence
   --  on the barrier:
   --
   --                      |
   --                 when BARRIER
   --                /            \
   --  (EC_Default) /              \ (EC_Barrier)
   --              /                \
   --          SUBPROGRAM          null
   --                    \         /
   --                     \---+---/
   --                         |

   procedure Do_Type_Declaration
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
   with Pre => Nkind (N) in N_Full_Type_Declaration |
                            N_Subtype_Declaration |
                            N_Private_Extension_Declaration;
   --  This ignores type declarations (but creates a sink vertex so we
   --  can check for use of uninitialized variables).

   procedure Process_Quantified_Expressions
     (L   : List_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context);
   --  This procedure goes through a given list of statements and
   --  recursively looks at each one, setting up the 'initial and
   --  'final vertices for symbols introduced by quantified
   --  expressions. We do not descend into nested subprograms, tasks
   --  or packages.

   procedure Process_Quantified_Expressions
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context);
   --  As above but operates on a single node.

   procedure Process_Parameter_Associations
     (Callsite : Node_Id;
      Ins      : in out Vertex_Vectors.Vector;
      Outs     : in out Vertex_Vectors.Vector;
      FA       : in out Flow_Analysis_Graphs;
      CM       : in out Connection_Maps.Map;
      Ctx      : in out Context);
   --  Similar to the above procedure, this deals with the actuals
   --  provided in a subprogram call. The vertices are created but not
   --  linked up; as above, they are appended to Ins and Outs.

   procedure Process_Statement
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
   with Post => Ctx'Old.Folded_Function_Checks.Length =
                Ctx.Folded_Function_Checks.Length;
   --  Process an arbitrary statement (this is basically a big case
   --  block which calls the various Do_XYZ procedures).

   procedure Process_Statement_List
     (L   : List_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context);
   --  This processes a list of statements and links up each statement
   --  to the its successor. The final connection map for L will map
   --  to the standard entry of the first statement and the standard
   --  exits of the last statement.

   procedure Process_Subprogram_Globals
     (Callsite : Node_Id;
      Ins      : in out Vertex_Vectors.Vector;
      Outs     : in out Vertex_Vectors.Vector;
      FA       : in out Flow_Analysis_Graphs;
      CM       : in out Connection_Maps.Map;
      Ctx      : in out Context);
   --  This procedures creates the in and out vertices for a
   --  subprogram's globals. They are not connected to anything,
   --  instead the vertices are appended to Ins and Outs.

   function RHS_Split_Useful (N     : Node_Id;
                              Scope : Flow_Scope)
                              return Boolean
   with Pre => Nkind (N) in N_Assignment_Statement  |
                            N_Component_Declaration |
                            N_Object_Declaration
               and then Present (Expression (N));
   --  Checks the right hand side of an assignment statement (or the
   --  expression on an object declaration) and determines if we can
   --  perform some meaningful record-field splitting.

   procedure Mark_Exceptional_Paths (FA : in out Flow_Analysis_Graphs);
   --  Set Is_Exceptional_Path on all vertices belonging to exceptional
   --  control flow, and Is_Exceptional_branch on all vertices leading into
   --  an exceptional path.

   procedure Prune_Exceptional_Paths (FA : in out Flow_Analysis_Graphs);
   --  Delete all vertices from exceptional paths from the control flow
   --  graph.

   procedure Separate_Dead_Paths (FA : in out Flow_Analysis_Graphs);
   --  Make sure dead code remains separate from the rest of the control
   --  flow graph, so that the post-dominance frontier can be constructed
   --  without errors.

   procedure Simplify_CFG (FA : in out Flow_Analysis_Graphs);
   --  Remove all null vertices from the control flow graph.

   function Pragma_Relevant_To_Flow (N : Node_Id) return Boolean
     with Pre => Nkind (N) = N_Pragma;
   --  Check if flow analysis cares about this particular pragma.

   ------------------------------------------------------------
   --  Local procedures and functions
   ------------------------------------------------------------

   ----------------------
   -- Copy_Connections --
   ----------------------

   procedure Copy_Connections (CM  : in out Connection_Maps.Map;
                               Dst : Union_Id;
                               Src : Union_Id)
   is
      C : constant Graph_Connections := CM (Src);
   begin
      CM.Include (Dst, C);
   end Copy_Connections;

   ----------------
   -- Add_Vertex --
   ----------------

   procedure Add_Vertex (FA : in out Flow_Analysis_Graphs;
                         F  : Flow_Id;
                         A  : V_Attributes)
   is
      V : Flow_Graphs.Vertex_Id;
   begin
      FA.CFG.Add_Vertex (F, V);
      FA.Atr.Insert (V, A);
   end Add_Vertex;

   procedure Add_Vertex (FA : in out Flow_Analysis_Graphs;
                         F  : Flow_Id;
                         A  : V_Attributes;
                         V  : out Flow_Graphs.Vertex_Id)
   is
   begin
      FA.CFG.Add_Vertex (F, V);
      FA.Atr.Insert (V, A);
   end Add_Vertex;

   procedure Add_Vertex (FA : in out Flow_Analysis_Graphs;
                         A  : V_Attributes;
                         V  : out Flow_Graphs.Vertex_Id)
   is
   begin
      FA.CFG.Add_Vertex (V);
      FA.Atr.Insert (V, A);
   end Add_Vertex;

   --------------
   --  Linkup  --
   --------------

   procedure Linkup (FA    : in out Flow_Analysis_Graphs;
                     Froms : Vertex_Sets.Set;
                     To    : Flow_Graphs.Vertex_Id)
   is
   begin
      for From of Froms loop
         Linkup (FA, From, To);
      end loop;
   end Linkup;

   procedure Linkup (FA    : in out Flow_Analysis_Graphs;
                     From  : Flow_Graphs.Vertex_Id;
                     To    : Flow_Graphs.Vertex_Id)
   is
      Col : Edge_Colours := EC_Default;

      function Get_Colour (V : Flow_Graphs.Vertex_Id) return Edge_Colours;
      --  Produce the correct colour for outbound edges depending on the
      --  execution kind of the given vertex.

      ----------------
      -- Get_Colour --
      ----------------

      function Get_Colour (V : Flow_Graphs.Vertex_Id) return Edge_Colours
        is (case FA.Atr (V).Execution is
               when Normal_Execution     => EC_Default,
               when Barrier              => EC_Barrier,
               when Abnormal_Termination => EC_Abend,
               when Infinite_Loop        => EC_Inf);
   begin
      if FA.Atr (From).Is_Parameter or FA.Atr (From).Is_Global_Parameter then
         Col := Get_Colour (FA.CFG.Get_Vertex (FA.Atr (From).Call_Vertex));
      elsif not FA.Atr (From).Is_Callsite then
         Col := Get_Colour (From);
      end if;
      FA.CFG.Add_Edge (From, To, Col);
   end Linkup;

   ----------
   -- Join --
   ----------

   procedure Join
     (FA    : in out Flow_Analysis_Graphs;
      CM    : in out Connection_Maps.Map;
      Nodes : Union_Lists.List;
      Block : out Graph_Connections)
   is
      Prev : Union_Id;
      V    : Flow_Graphs.Vertex_Id;
   begin
      Block := No_Connections;

      Prev := Union_Id (Empty);
      for P of Nodes loop
         if Prev /= Empty_List_Or_Node then
            --  Connect this statement to the previous one.
            Linkup (FA,
                    CM (Prev).Standard_Exits,
                    CM (P).Standard_Entry);
         else
            --  This is the first vertex, so set the standard entry of
            --  the list.
            Block.Standard_Entry := CM (P).Standard_Entry;
         end if;

         Prev := P;
      end loop;

      if Prev /= Empty_List_Or_Node then
         --  Set the standard exits of the list, if we processed at
         --  least one element.
         Block.Standard_Exits := CM (Prev).Standard_Exits;
      else
         --  We had a null sequence so we need to produce a null node.
         Add_Vertex (FA, Null_Node_Attributes, V);
         Block.Standard_Entry := V;
         Block.Standard_Exits := To_Set (V);
      end if;
   end Join;

   ------------------------
   -- Create_Record_Tree --
   ------------------------

   procedure Create_Record_Tree
     (F        : Flow_Id;
      Leaf_Atr : V_Attributes;
      FA       : in out Flow_Analysis_Graphs)
   is
   begin
      if Is_Record_Discriminant (F)
        or else Belongs_To_Protected_Object (F)
      then
         --  The discriminants (for example r.x.d) do not live in the tree,
         --  but we should make the parent tree anyway, so that we get the
         --  important root node (in this example r). This is important for
         --  discriminated null records which have no other way of
         --  producing this otherwise.
         --
         --  Notice that discriminants of tasks are excluded from the creation
         --  of the corresponding group vertex.
         declare
            P : constant Flow_Id :=
              Change_Variant (Entire_Variable (F),
                              Corresponding_Grouping (F.Variant));
         begin
            Create_Record_Tree (P, Leaf_Atr, FA);
         end;
         return;
      end if;

      case F.Variant is
         when Normal_Use | In_View | Out_View =>
            raise Program_Error;

         when Initial_Value | Final_Value =>
            case F.Kind is
               when Null_Value =>
                  raise Program_Error;
               when Magic_String | Synthetic_Null_Export =>
                  null;
               when Direct_Mapping | Record_Field =>
                  if F.Kind = Record_Field
                    or else F.Facet in Private_Part | Extension_Part
                    or else Belongs_To_Protected_Object (F)
                  then
                     declare
                        P : constant Flow_Id :=
                          Change_Variant (Parent_Record (F),
                                          Corresponding_Grouping (F.Variant));
                     begin
                        Create_Record_Tree (P, Leaf_Atr, FA);
                        Linkup (FA,
                                FA.CFG.Get_Vertex (P),
                                FA.CFG.Get_Vertex (F));
                     end;
                  end if;
            end case;

         when Initial_Grouping | Final_Grouping =>
            case F.Kind is
               when Null_Value =>
                  raise Program_Error;
               when Direct_Mapping | Record_Field =>
                  --  Only proceed if we don't have this vertex yet.
                  if FA.CFG.Get_Vertex (F) = Flow_Graphs.Null_Vertex then
                     --  Create vertex.
                     Add_Vertex
                       (FA,
                        F,
                        Make_Record_Tree_Attributes (Leaf_Atr));

                     if F.Kind = Record_Field then
                        Create_Record_Tree (Parent_Record (F), Leaf_Atr, FA);
                        Linkup (FA,
                                FA.CFG.Get_Vertex (Parent_Record (F)),
                                FA.CFG.Get_Vertex (F));
                     end if;
                  end if;
               when Magic_String | Synthetic_Null_Export =>
                  null;
            end case;
      end case;
   end Create_Record_Tree;

   ---------------------------------------
   -- Create_Initial_And_Final_Vertices --
   ----------------------------------------

   procedure Create_Initial_And_Final_Vertices
     (E    : Entity_Id;
      Kind : Var_Kind;
      FA   : in out Flow_Analysis_Graphs)
   is
      M : Param_Mode;

      procedure Process (F : Flow_Id);

      -------------
      -- Process --
      -------------

      procedure Process (F : Flow_Id) is
         V : Flow_Graphs.Vertex_Id;
         A : V_Attributes;
      begin
         --  Setup the n'initial vertex. Note that initialization for
         --  variables is detected (and set) when building the flow graph
         --  for declarative parts.
         A := Make_Variable_Attributes
           (FA    => FA,
            F_Ent => Change_Variant (F, Initial_Value),
            Mode  => M,
            E_Loc => E);

         Add_Vertex
           (FA,
            Change_Variant (F, Initial_Value),
            A,
            V);
         Linkup (FA, V, FA.Start_Vertex);

         Create_Record_Tree (Change_Variant (F, Initial_Value),
                             A,
                             FA);

         --  Setup the n'final vertex.
         Add_Vertex
           (FA,
            Change_Variant (F, Final_Value),
            Make_Variable_Attributes (FA    => FA,
                                      F_Ent => Change_Variant (F, Final_Value),
                                      Mode  => M,
                                      E_Loc => E),
            V);
         Linkup (FA, FA.End_Vertex, V);

         FA.All_Vars.Include (F);
      end Process;

   begin
      if Ekind (E) = E_Constant and not FA.Local_Constants.Contains (E) then
         --  We ignore non-local constants (for now).
         return;
      end if;

      case Ekind (E) is
         when E_Out_Parameter    =>
            pragma Assert (Kind = Parameter_Kind);
            M := Mode_Out;

         when E_In_Out_Parameter =>
            pragma Assert (Kind = Parameter_Kind);
            M := Mode_In_Out;

         when E_In_Parameter     =>
            pragma Assert (Kind = Parameter_Kind);
            M := Mode_In;

         when E_Discriminant     =>
            pragma Assert (Kind in Discriminant_Kind | Parameter_Kind);
            M := Mode_In;

         when Concurrent_Kind    =>
            pragma Assert (Kind = Parameter_Kind);
            if Ekind (FA.Analyzed_Entity) = E_Function then
               M := Mode_In;
            else
               M := Mode_In_Out;
            end if;

         when others =>
            pragma Assert (Kind in Parameter_Kind           |
                                   Quantified_Variable_Kind |
                                   Variable_Kind);
            if Kind = Parameter_Kind then
               if Ekind (FA.Analyzed_Entity) = E_Function then
                  M := Mode_In;
               else
                  M := Mode_In_Out;
               end if;
            elsif Kind = Quantified_Variable_Kind then
               M := Mode_In;
            else
               M := Mode_Invalid;
            end if;
      end case;

      declare
         FS : constant Flow_Id_Sets.Set := Flatten_Variable (E, FA.B_Scope);
      begin
         for Tmp of FS loop
            Process (Tmp);
            if Has_Bounds (Tmp, FA.B_Scope) then
               Process (Tmp'Update (Facet => The_Bounds));
            end if;
         end loop;
      end;

      if Extensions_Visible (E, FA.B_Scope) then
         Process (Direct_Mapping_Id (E, Facet => Extension_Part));
      end if;
   end Create_Initial_And_Final_Vertices;

   procedure Create_Initial_And_Final_Vertices
     (F             : Flow_Id;
      Mode          : Param_Mode;
      Uninitialized : Boolean;
      FA            : in out Flow_Analysis_Graphs)
   is
      procedure Process (F : Flow_Id);

      -------------
      -- Process --
      -------------

      procedure Process (F : Flow_Id) is
         A : V_Attributes;
         V : Flow_Graphs.Vertex_Id;
      begin
         --  Setup the n'initial vertex. Initialization is deduced from
         --  the mode.
         A := Make_Global_Variable_Attributes
           (FA     => FA,
            F      => Change_Variant (F, Initial_Value),
            Mode   => Mode,
            Uninit => Uninitialized);
         Add_Vertex
           (FA,
            Change_Variant (F, Initial_Value),
            A,
            V);
         Linkup (FA, V, FA.Start_Vertex);

         Create_Record_Tree (Change_Variant (F, Initial_Value),
                             A,
                             FA);

         --  Setup the n'final vertex.
         Add_Vertex
           (FA,
            Change_Variant (F, Final_Value),
            Make_Global_Variable_Attributes
              (FA   => FA,
               F    => Change_Variant (F, Final_Value),
               Mode => Mode),
            V);
         Linkup (FA, FA.End_Vertex, V);

         FA.All_Vars.Include (F);
      end Process;

      FS : Flow_Id_Sets.Set;

   --  Start of processing for Create_Initial_And_Final_Vertices

   begin
      FS := Flatten_Variable (F, FA.B_Scope);
      for Tmp of FS loop
         Process (Tmp);
         if Has_Bounds (Tmp, FA.B_Scope) then
            Process (Tmp'Update (Facet => The_Bounds));
         end if;
      end loop;

      if Extensions_Visible (F, FA.B_Scope) then
         Process (F'Update (Facet => Extension_Part));
      end if;
   end Create_Initial_And_Final_Vertices;

   ----------------------
   -- Replace_Flow_Ids --
   ----------------------

   function Replace_Flow_Ids
     (Of_This   : Entity_Id;
      With_This : Entity_Id;
      The_Set   : Flow_Id_Sets.Set)
      return Flow_Id_Sets.Set
   is
      FS : Flow_Id_Sets.Set := Flow_Id_Sets.Empty_Set;
   begin
      for F of The_Set loop
         if F.Kind in Direct_Mapping | Record_Field
           and then F.Node = Of_This
         then
            FS.Include (F'Update (Node => With_This));
         else
            FS.Include (F);
         end if;
      end loop;
      return FS;
   end Replace_Flow_Ids;

   -------------------------------
   --  Do_Assignment_Statement  --
   -------------------------------

   procedure Do_Assignment_Statement
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
   is
      Funcs : Node_Sets.Set;

      V     : Flow_Graphs.Vertex_Id;
      Verts : Vertex_Vectors.Vector := Vertex_Vectors.Empty_Vector;

      Partial         : Boolean;
      View_Conversion : Boolean;
      Classwide       : Boolean;
      Map_Root        : Flow_Id;
      To_Cw           : constant Boolean :=
        Is_Class_Wide_Type (Get_Type (Name (N), FA.B_Scope)) and then
          not Is_Class_Wide_Type (Get_Type (Expression (N), FA.B_Scope));

   begin
      Collect_Functions_And_Read_Locked_POs
        (Expression (N),
         Functions_Called   => Funcs,
         Tasking            => FA.Tasking,
         Include_Predicates => FA.Generating_Globals);

      --  First we need to determine the root name where we assign to, and
      --  whether this is a partial or full assignment. This mirror the
      --  beginning of Untangle_Assignment_Target.

      declare
         Unused : Node_Lists.List;
      begin
         Get_Assignment_Target_Properties
           (Name (N),
            Partial_Definition => Partial,
            View_Conversion    => View_Conversion,
            Classwide          => Classwide,
            Map_Root           => Map_Root,
            Seq                => Unused);
      end;

      --  We have two likely scenarios: some kind of record assignment (in
      --  which case we try our best to dis-entangle the record fields so
      --  that information does not bleed all over the place) and the
      --  default case.

      if not Partial and then RHS_Split_Useful (N, FA.B_Scope) then
         declare
            M            : Flow_Id_Maps.Map;
            Output       : Flow_Id;
            Inputs       : Flow_Id_Sets.Set;
            All_Vertices : Vertex_Sets.Set  := Vertex_Sets.Empty_Set;
            Missing      : Flow_Id_Sets.Set;
         begin
            M := Untangle_Record_Assignment
              (Expression (N),
               Map_Root                     => Map_Root,
               Map_Type                     => Get_Type (Name (N), FA.B_Scope),
               Scope                        => FA.B_Scope,
               Local_Constants              => FA.Local_Constants,
               Fold_Functions               => True,
               Use_Computed_Globals         => not FA.Generating_Globals,
               Expand_Synthesized_Constants => False);

            Missing := Flatten_Variable (Map_Root, FA.B_Scope);
            if Is_Class_Wide_Type (Get_Type (Name (N), FA.B_Scope))
              and then Map_Root.Kind = Direct_Mapping
            then
               Missing.Include (Map_Root'Update (Facet => Extension_Part));
            end if;

            --  Split out the assignment over a number of vertices.
            for C in M.Iterate loop
               Output := Flow_Id_Maps.Key (C);
               Inputs := Flow_Id_Maps.Element (C);

               Missing.Delete (Output);

               Add_Vertex
                 (FA,
                  Make_Basic_Attributes
                    (FA         => FA,
                     Var_Def    => Flow_Id_Sets.To_Set (Output),
                     Var_Ex_Use => Inputs,
                     Sub_Called => Funcs,
                     Loops      => Ctx.Current_Loops,
                     E_Loc      => N,
                     Print_Hint => Pretty_Print_Record_Field),
                  V);
               Verts.Append (V);
               All_Vertices.Insert (V);
            end loop;

            if not View_Conversion then
               --  There might be some fields missing, but if this is not a
               --  view conversion (and we have already established its a
               --  full assignment), flow analysis must not claim any other
               --  fields are "uninitialized".
               for F of Missing loop
                  Add_Vertex
                    (FA,
                     Make_Basic_Attributes
                       (FA         => FA,
                        Var_Def    => Flow_Id_Sets.To_Set (F),
                        Var_Ex_Use => Flow_Id_Sets.Empty_Set,
                        Sub_Called => Node_Sets.Empty_Set,
                        Loops      => Ctx.Current_Loops,
                        E_Loc      => N,
                        Print_Hint => Pretty_Print_Record_Field),
                     V);
                  Verts.Append (V);
                  All_Vertices.Insert (V);
               end loop;
            end if;

            declare
               C : Flow_Graphs.Cluster_Id;
            begin
               FA.CFG.New_Cluster (C);
               for V of All_Vertices loop
                  FA.Other_Fields.Insert
                    (V,
                     All_Vertices - Vertex_Sets.To_Set (V));
                  FA.CFG.Set_Cluster (V, C);
               end loop;
            end;
         end;
      else
         declare
            Vars_Defined : Flow_Id_Sets.Set;
            Vars_Used    : Flow_Id_Sets.Set;
            Vars_Proof   : Flow_Id_Sets.Set;
         begin
            --  Work out which variables we define.
            Untangle_Assignment_Target
              (N                    => Name (N),
               Scope                => FA.B_Scope,
               Local_Constants      => FA.Local_Constants,
               Use_Computed_Globals => not FA.Generating_Globals,
               Vars_Defined         => Vars_Defined,
               Vars_Used            => Vars_Used,
               Vars_Proof           => Vars_Proof,
               Partial_Definition   => Partial);

            --  Work out the variables we use. These are the ones already
            --  used by the LHS + everything on the RHS.
            Vars_Used.Union
              (Get_Variable_Set
                 (Expression (N),
                  Scope                => FA.B_Scope,
                  Local_Constants      => FA.Local_Constants,
                  Fold_Functions       => True,
                  Use_Computed_Globals => not FA.Generating_Globals,
                  Consider_Extensions  => To_Cw));

            --  Any proof variables we need to check separately. We also
            --  need to check the RHS for proof variables.
            Ctx.Folded_Function_Checks (N).Insert (Expression (N));
            if not Vars_Proof.Is_Empty then
               Ctx.Folded_Function_Checks (N).Insert (Name (N));
            end if;

            --  Produce the vertex.
            Add_Vertex
              (FA,
               Direct_Mapping_Id (N),
               Make_Basic_Attributes
                 (FA         => FA,
                  Var_Def    => Vars_Defined,
                  Var_Ex_Use => Vars_Used,
                  Var_Im_Use => (if Partial
                                 then Vars_Defined
                                 else Flow_Id_Sets.Empty_Set),
                  Sub_Called => Funcs,
                  Loops      => Ctx.Current_Loops,
                  E_Loc      => N),
               V);
            Verts.Append (V);
         end;
      end if;

      --  Finally, we join up all the vertices we have produced and record
      --  update the connection map. ??? record update

      if Verts.Is_Empty then
         pragma Assert (Is_Null_Record (Etype (Name (N))));
         --  Assigning null records does not produce any assignments, so we
         --  create a null vertex instead.
         Add_Vertex (FA,
                     Direct_Mapping_Id (N),
                     Null_Node_Attributes,
                     V);
         Verts.Append (V);
      end if;

      V := Flow_Graphs.Null_Vertex;
      for W of Verts loop
         if V /= Flow_Graphs.Null_Vertex then
            Linkup (FA, V, W);
         end if;
         V := W;
      end loop;

      CM.Include (Union_Id (N),
                  Graph_Connections'
                    (Standard_Entry => Verts.First_Element,
                     Standard_Exits => To_Set (Verts.Last_Element)));
   end Do_Assignment_Statement;

   -------------------------
   --  Do_Case_Statement  --
   -------------------------

   procedure Do_Case_Statement
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
   is
      V, V_Alter  : Flow_Graphs.Vertex_Id;
      Alternative : Node_Id;
      Funcs       : Node_Sets.Set;
   begin
      Collect_Functions_And_Read_Locked_POs
        (Expression (N),
         Functions_Called   => Funcs,
         Tasking            => FA.Tasking,
         Include_Predicates => FA.Generating_Globals);

      --  We have a vertex V for the case statement itself
      Add_Vertex
        (FA,
         Direct_Mapping_Id (N),
         Make_Basic_Attributes
           (FA         => FA,
            Var_Ex_Use => Get_Variable_Set
              (Expression (N),
               Scope                => FA.B_Scope,
               Local_Constants      => FA.Local_Constants,
               Fold_Functions       => True,
               Use_Computed_Globals => not FA.Generating_Globals),
            Sub_Called => Funcs,
            Loops      => Ctx.Current_Loops,
            E_Loc      => N),
         V);
      Ctx.Folded_Function_Checks (N).Insert (Expression (N));
      CM.Include (Union_Id (N), No_Connections);
      CM (Union_Id (N)).Standard_Entry := V;

      Alternative := First (Alternatives (N));

      while Present (Alternative) loop
         --  We introduce a vertex V_Alter for each
         --  Case_Statement_Alternative and we link that to V.
         Add_Vertex
           (FA,
            Direct_Mapping_Id (Alternative),
            Make_Aux_Vertex_Attributes (E_Loc => Alternative),
            V_Alter);
         Linkup (FA, V, V_Alter);

         --  We link V_Alter with its statements
         Process_Statement_List (Statements (Alternative), FA, CM, Ctx);
         Linkup (FA,
                 V_Alter,
                 CM (Union_Id (Statements (Alternative))).Standard_Entry);
         CM (Union_Id (N)).Standard_Exits.Union
           (CM (Union_Id (Statements (Alternative))).Standard_Exits);

         Next (Alternative);
      end loop;
   end Do_Case_Statement;

   ------------------------
   -- Do_Delay_Statement --
   ------------------------

   procedure Do_Delay_Statement
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
   is
      V         : Flow_Graphs.Vertex_Id;
      Vars_Used : Flow_Id_Sets.Set;
      Funcs     : Node_Sets.Set;
   begin
      --  Gather variables used in the expression of the delay statement
      Vars_Used := Get_Variable_Set
                     (Expression (N),
                      Scope                => FA.B_Scope,
                      Local_Constants      => FA.Local_Constants,
                      Fold_Functions       => True,
                      Use_Computed_Globals => not FA.Generating_Globals);

      --  Add the implicit use of Ada.Real_Time.Clock_Time
      Vars_Used.Include
        (Get_Flow_Id (To_Entity_Name ("ada__real_time__clock_time"),
                      Normal_Use,
                      FA.B_Scope));

      Collect_Functions_And_Read_Locked_POs
        (Expression (N),
         Functions_Called   => Funcs,
         Tasking            => FA.Tasking,
         Include_Predicates => FA.Generating_Globals);

      Add_Vertex
        (FA,
         Direct_Mapping_Id (N),
         Make_Basic_Attributes
           (FA,
            Var_Ex_Use => Vars_Used,
            Sub_Called => Funcs,
            Loops      => Ctx.Current_Loops,
            E_Loc      => N),
         V);
      CM.Include (Union_Id (N), Trivial_Connection (V));
   end Do_Delay_Statement;

   -------------------------
   --  Do_Exit_Statement  --
   -------------------------

   procedure Do_Exit_Statement
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
   is
      V     : Flow_Graphs.Vertex_Id;
      L     : Node_Id := N;
      Funcs : Node_Sets.Set;
   begin
      --  Go up the tree until we find the loop we are exiting from.
      if No (Name (N)) then
         --  We just need to find the enclosing loop.
         loop
            L := Parent (L);
            exit when Nkind (L) = N_Loop_Statement;
         end loop;
      else
         --  We have a named loop, which we need to find.
         loop
            L := Parent (L);
            exit when Nkind (L) = N_Loop_Statement and then
              Entity (Identifier (L)) = Entity (Name (N));
         end loop;
      end if;

      --  Conditional and unconditional exits are different. One
      --  requires an extra vertex, the other does not.
      if No (Condition (N)) then
         Add_Vertex (FA,
                     Direct_Mapping_Id (N),
                     Null_Node_Attributes,
                     V);
         CM.Include (Union_Id (N),
                     Graph_Connections'
                       (Standard_Entry => V,
                        Standard_Exits => Vertex_Sets.Empty_Set));

         CM (Union_Id (L)).Standard_Exits.Include (V);

      else

         Collect_Functions_And_Read_Locked_POs
           (Condition (N),
            Functions_Called   => Funcs,
            Tasking            => FA.Tasking,
            Include_Predicates => FA.Generating_Globals);

         Add_Vertex
           (FA,
            Direct_Mapping_Id (N),
            Make_Basic_Attributes
              (FA         => FA,
               Var_Ex_Use => Get_Variable_Set
                 (Condition (N),
                  Scope                => FA.B_Scope,
                  Local_Constants      => FA.Local_Constants,
                  Fold_Functions       => True,
                  Use_Computed_Globals => not FA.Generating_Globals),
               Sub_Called => Funcs,
               Loops      => Ctx.Current_Loops,
               E_Loc      => N),
            V);
         Ctx.Folded_Function_Checks (N).Insert (Condition (N));
         CM.Include (Union_Id (N),
                     Trivial_Connection (V));

         CM (Union_Id (L)).Standard_Exits.Include (V);
      end if;
   end Do_Exit_Statement;

   ----------------------------------
   -- Do_Extended_Return_Statement --
   ----------------------------------

   procedure Do_Extended_Return_Statement
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
   is
      V            : Flow_Graphs.Vertex_Id;
      Ret_Object_L : constant List_Id := Return_Object_Declarations (N);
      Ret_Entity   : constant Node_Id := Return_Statement_Entity (N);
      Ret_Object   : Node_Id;
      Funcs        : Node_Sets.Set;
   begin
      --  We create a null vertex for the extended return statement
      Add_Vertex
        (FA,
         Direct_Mapping_Id (N),
         Null_Node_Attributes,
         V);
      --  Control flows in, but we do not flow out again.
      CM.Include (Union_Id (N),
                  Graph_Connections'(Standard_Entry => V,
                                     Standard_Exits => Empty_Set));

      --  Go through Ret_Object_L list and locate Ret_Object
      Ret_Object := First (Ret_Object_L);
      while Nkind (Ret_Object) /= N_Object_Declaration
        or else not Is_Return_Object (Defining_Identifier (Ret_Object))
      loop
         Ret_Object := Next (Ret_Object);
         pragma Assert (Present (Ret_Object));
      end loop;
      Ret_Object := Defining_Identifier (Ret_Object);

      --  Process the statements of Ret_Object_L
      Process_Statement_List (Ret_Object_L, FA, CM, Ctx);

      --  Link the entry vertex V (the extended return statement) to
      --  standard entry of its return_object_declarations.
      Linkup (FA, V, CM (Union_Id (Ret_Object_L)).Standard_Entry);

      --  Create a vertex for the Return_Statement_Entity
      Collect_Functions_And_Read_Locked_POs
        (Ret_Object,
         Functions_Called   => Funcs,
         Tasking            => FA.Tasking,
         Include_Predicates => FA.Generating_Globals);

      Add_Vertex
        (FA,
         Direct_Mapping_Id (Ret_Entity),
         Make_Extended_Return_Attributes
           (FA              => FA,
            Var_Def         => Flatten_Variable (FA.Analyzed_Entity,
                                                 FA.B_Scope),
            Var_Use         => Flatten_Variable (Ret_Object,
                                                 FA.B_Scope),
            Object_Returned => Ret_Object,
            Sub_Called      => Funcs,
            --  ??? really? I don't think we can call a function here...
            Loops           => Ctx.Current_Loops,
            E_Loc           => Ret_Entity),
         V);
      CM.Include (Union_Id (Ret_Entity), No_Connections);
      CM (Union_Id (Ret_Entity)).Standard_Entry := V;

      if Present (Handled_Statement_Sequence (N)) then
         declare
            Statement_Sequence : constant List_Id :=
              Statements (Handled_Statement_Sequence (N));
         begin
            --  We process the sequence of statements
            Process_Statement_List (Statement_Sequence, FA, CM, Ctx);
            --  We link the standard exits of Ret_Object_L to the standard
            --  entry of the sequence of statements.
            Linkup (FA,
                    CM (Union_Id (Ret_Object_L)).Standard_Exits,
                    CM (Union_Id (Statement_Sequence)).Standard_Entry);

            --  We link the standard exits of the sequence of
            --  statements to the standard entry of the implicit
            --  return statement.
            Linkup (FA, CM (Union_Id (Statement_Sequence)).Standard_Exits, V);
         end;
      else
         --  No sequence of statements is present. We link the
         --  standard exits of Ret_Object_L to the implicit return
         --  statement.
         Linkup (FA, CM (Union_Id (Ret_Object_L)).Standard_Exits, V);
      end if;

      --  We link the implicit return statement to the helper end vertex
      Linkup (FA, V, FA.Helper_End_Vertex);
   end Do_Extended_Return_Statement;

   -----------------------------------------
   --  Do_Handled_Sequence_Of_Statements  --
   -----------------------------------------

   procedure Do_Handled_Sequence_Of_Statements
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
   is
      Stmts : constant List_Id := Statements (N);
   begin
      Process_Statement_List (Stmts, FA, CM, Ctx);
      Copy_Connections (CM,
                        Dst => Union_Id (N),
                        Src => Union_Id (Stmts));
   end Do_Handled_Sequence_Of_Statements;

   -----------------------
   --  Do_If_Statement  --
   -----------------------

   procedure Do_If_Statement
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
   is
      V, V_Prev       : Flow_Graphs.Vertex_Id;
      If_Part         : constant List_Id := Then_Statements (N);
      Else_Part       : constant List_Id := Else_Statements (N);
      Elsif_Part      : constant List_Id := Elsif_Parts (N);
      Elsif_Statement : Node_Id;
      Funcs           : Node_Sets.Set;
   begin
      --  We have a vertex for the if statement itself.
      Collect_Functions_And_Read_Locked_POs
        (Condition (N),
         Functions_Called   => Funcs,
         Tasking            => FA.Tasking,
         Include_Predicates => FA.Generating_Globals);

      Add_Vertex
        (FA,
         Direct_Mapping_Id (N),
         Make_Basic_Attributes
           (FA         => FA,
            Var_Ex_Use => Get_Variable_Set
              (Condition (N),
               Scope                => FA.B_Scope,
               Local_Constants      => FA.Local_Constants,
               Fold_Functions       => True,
               Use_Computed_Globals => not FA.Generating_Globals),
            Sub_Called => Funcs,
            Loops      => Ctx.Current_Loops,
            E_Loc      => N),
         V);
      Ctx.Folded_Function_Checks (N).Insert (Condition (N));
      CM.Include (Union_Id (N), No_Connections);
      CM (Union_Id (N)).Standard_Entry := V;

      --  We hang the if part off that.
      Process_Statement_List (If_Part, FA, CM, Ctx);
      Linkup (FA, V, CM (Union_Id (If_Part)).Standard_Entry);
      CM (Union_Id (N)).Standard_Exits.Union
        (CM (Union_Id (If_Part)).Standard_Exits);

      --  If we have elsif parts we chain them together in the obvious
      --  way:
      --
      --  if
      --  | \
      --  |  if part
      --  |         \-----------------
      --  elsif                       \
      --  |    \                       |
      --  |     elsif part             |
      --  |               \---------   |
      --  elsif                     \  |
      --  |    \                     | |
      --  |     another elsif part   | |
      --  |                       \  | |
      --  (optional else part)     | | |
      --
      --  The standard exits for all parts feed into the standard
      --  exits of the entire if statement.
      --
      --  Finally please note that at the end variable V is either the
      --  vertex for the if statement itself or the very last elsif
      --  part.

      if Elsif_Part /= No_List then
         Elsif_Statement := First (Elsif_Part);
         V_Prev          := V;

         while Present (Elsif_Statement) loop
            declare
               Elsif_Body : constant List_Id :=
                 Then_Statements (Elsif_Statement);
               Funcs      : Node_Sets.Set;
            begin
               --  We have a vertex V for each elsif statement
               Collect_Functions_And_Read_Locked_POs
                 (Condition (Elsif_Statement),
                  Functions_Called   => Funcs,
                  Tasking            => FA.Tasking,
                  Include_Predicates => FA.Generating_Globals);

               Add_Vertex
                 (FA,
                  Direct_Mapping_Id (Elsif_Statement),
                  Make_Basic_Attributes
                    (FA         => FA,
                     Var_Ex_Use => Get_Variable_Set
                       (Condition (Elsif_Statement),
                        Scope                => FA.B_Scope,
                        Local_Constants      => FA.Local_Constants,
                        Fold_Functions       => True,
                        Use_Computed_Globals => not FA.Generating_Globals),
                     Sub_Called => Funcs,
                     Loops      => Ctx.Current_Loops,
                     E_Loc      => Elsif_Statement),
                  V);
               Ctx.Folded_Function_Checks (N).Insert
                 (Condition (Elsif_Statement));

               --  Link V_Prev to V
               Linkup (FA, V_Prev, V);

               --  Process statements of elsif and link V to them
               Process_Statement_List (Elsif_Body, FA, CM, Ctx);
               Linkup (FA, V, CM (Union_Id (Elsif_Body)).Standard_Entry);

               --  Add the exits of Elsif_Body to the exits of N
               CM (Union_Id (N)).Standard_Exits.Union
                 (CM (Union_Id (Elsif_Body)).Standard_Exits);
            end;

            V_Prev := V;
            Next (Elsif_Statement);
         end loop;
      end if;

      --  Remember that V is the vertex associated with either the
      --  last elsif blob or the if statement itself.

      if Else_Part /= No_List then
         Process_Statement_List (Else_Part, FA, CM, Ctx);
         Linkup (FA, V, CM (Union_Id (Else_Part)).Standard_Entry);
         CM (Union_Id (N)).Standard_Exits.Union
           (CM (Union_Id (Else_Part)).Standard_Exits);
      else
         CM (Union_Id (N)).Standard_Exits.Insert (V);
      end if;
   end Do_If_Statement;

   -------------------------
   --  Do_Loop_Statement  --
   -------------------------

   procedure Do_Loop_Statement
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
   is
      function Is_For_Loop (N : Node_Id) return Boolean
      is (Nkind (N) = N_Loop_Statement
            and then Present (Iteration_Scheme (N))
            and then Present (Loop_Parameter_Specification
                                (Iteration_Scheme (N))));
      --  Check if the given loop is a simlpe for loop.

      function Get_Loop_Variable (N : Node_Id) return Entity_Id
      is (Defining_Identifier
            (Loop_Parameter_Specification (Iteration_Scheme (N))))
      with Pre => Is_For_Loop (N);
      --  Obtain the entity of a for loops loop parameter.

      function Get_Loop_Name (N : Node_Id) return Entity_Id
      is (Entity (Identifier (N)));
      --  Obtain the entity of loop's label.

      function Get_Loop_Range (N : Node_Id) return Node_Id
      with Pre => Is_For_Loop (N);
      --  Return the range given for loop.

      function Loop_Might_Exit_Early (N : Node_Id) return Boolean;
      --  Return true if the loop contains an exit or return statement.

      procedure Do_Loop;
      --  Helper procedure to deal with normal loops.
      --
      --  We have two cases: Infinite loops and not-so-infinite loops.
      --
      --  For the infinite loop case we do not have exit or return
      --  statements in the loop. To get a mostly connected graph
      --  (there should be at least a path start -> end) we will
      --  pretend there is an "exit when False" statement at the end
      --  of the loop. Thus:
      --
      --        |
      --        +<----\
      --        |     |
      --        v     |
      --       BODY   |
      --        |  \--/
      --        v
      --
      --  If we would not do this we would get a null derives for the
      --  enclosing subprogram (along with some exceptions thrown by
      --  the dominator tree algorithm).
      --
      --  If we have at least one exit statement (for this loop) or a
      --  return statement we do not need to put in this faux exit.

      procedure Do_While_Loop;
      --  Helper procedure to deal with while loops.
      --
      --  This is actually the most simple of the loops. We generate
      --  the following graph:
      --
      --       |
      --       v
      --   CONDITION --\
      --   ^   |       |
      --   |   v       |
      --   |  BODY     |
      --   |   |       |
      --   \---/       v

      procedure Do_For_Loop (Fully_Initialized : out Flow_Id_Sets.Set);
      --  Helper procedure to deal with for loops.
      --
      --  We must distinguish between three kinds of for loops,
      --  depending on the range. It can be definitely empty,
      --  definitely non-empty and unknown.
      --
      --  For the "definitely empty" case we never connect the loop
      --  body:
      --
      --       |
      --       v
      --    PARAMETER         BODY
      --       |
      --       v
      --
      --  This will produce flow errors, which is what we want.
      --
      --  For the "unknown" case we have a construct similar to a
      --  while loop:
      --
      --       |
      --       v
      --   PARAMETER --\
      --   ^   |       |
      --   |   v       |
      --   |  BODY     |
      --   |   |       |
      --   \---/       v
      --
      --  This means the loop body may not be executed, so any
      --  initializations in the loop which subsequent code depends on
      --  will be flagged up.
      --
      --  Finally, for the "definitely non-empty" case we employ a
      --  creative hack. We move the parameter definition behind the
      --  loop body, which means there are no paths that never execute
      --  the loop. Any dependency on the parameter (for example if
      --  the user wrote range A .. B) is irrelevant as it must be
      --  static in the first place and thus there can't be any
      --  dependencies. Thus:
      --
      --        |
      --        v
      --       BODY <---\
      --        |       |
      --        v       |
      --    PARAMETER --/
      --        |
      --        v
      --
      --  The PARAMETER block defines the loop parameter (which is
      --  also flagged as Is_Initialized and Is_Loop_Parameter so that
      --  it can be suitably ignored by subsequent analysis).
      --
      --  We distinguish this case (non-empty range) from the previous
      --  one (unknown range) as subsequent code may rely on any
      --  initializations in the loop body.

      procedure Do_Iterator_Loop;
      --  Helper procedure to deal with for loops using iterators. Very
      --  similar to general for loops, except that we always produce
      --  unknown-if-executed loops.
      --
      --       |
      --       v
      --   PARAMETER --\
      --   ^   |       |
      --   |   v       |
      --   |  BODY     |
      --   |   |       |
      --   \---/       v
      --
      --  This means the loop body may not be executed, so any
      --  initializations in the loop which subsequent code depends on
      --  will be flagged up.

      function Variables_Initialized_By_Loop (N : Node_Id)
                                              return Flow_Id_Sets.Set;
      --  A conservative heuristic to determine the set of possible
      --  variables fully initialized by the given statement list.

      --------------------
      -- Get_Loop_Range --
      --------------------

      function Get_Loop_Range (N : Node_Id) return Node_Id is
         DSD : constant Node_Id := Discrete_Subtype_Definition
           (Loop_Parameter_Specification (Iteration_Scheme (N)));

         R : Node_Id;
      begin
         case Nkind (DSD) is
            when N_Subtype_Indication =>
               case Nkind (Constraint (DSD)) is
                  when N_Range_Constraint =>
                     R := Range_Expression (Constraint (DSD));
                  when others =>
                     raise Why.Unexpected_Node;
               end case;
            when N_Identifier | N_Expanded_Name =>
               R := Get_Range (Entity (DSD));
            when N_Range =>
               R := DSD;
            when others =>
               Print_Node_Subtree (DSD);
               raise Why.Unexpected_Node;
         end case;
         return R;
      end Get_Loop_Range;

      -------------
      -- Do_Loop --
      -------------

      procedure Do_Loop is
         Contains_Return : Boolean := False;

         function Proc (N : Node_Id) return Traverse_Result;
         --  Set Contains_Return to true if we find a return statement.

         function Proc (N : Node_Id) return Traverse_Result
         is
         begin
            case Nkind (N) is
               when N_Simple_Return_Statement |
                 N_Extended_Return_Statement =>
                  Contains_Return := True;
                  return Abandon;
               when others =>
                  return OK;
            end case;
         end Proc;

         procedure Find_Return is new Traverse_Proc (Process => Proc);

         V           : Flow_Graphs.Vertex_Id;
         Faux_Exit_V : Flow_Graphs.Vertex_Id;

      begin
         --  Check if we have a return statement.
         Find_Return (N);

         --  We have a null vertex for the loop, as we have no
         --  condition.
         Add_Vertex (FA,
                     Direct_Mapping_Id (N),
                     Null_Node_Attributes,
                     V);

         --  Entry point for the loop is V.
         CM (Union_Id (N)).Standard_Entry := V;

         --  Exit from the loop is at the end of the loop, i.e. we are
         --  always going round at least once.
         if Contains_Return then
            --  If the loop contains a return statement we do not add
            --  the faux exit.
            null;
         elsif CM (Union_Id (N)).Standard_Exits.Length > 0 then
            --  If we already have a standard exit that means an exit
            --  statement added it. We don't need the faux exit.
            null;
         else
            --  We have neither return nor exit, so we simulate an
            --  "exit when false" at the end of the loop.

            --  We need a previously unused node, we can abuse the end
            --  label for this. This represents our "exit when false"
            --  node. We cannot just add a fake exit to the very last
            --  vertex in the loop body, as this introduces
            --  interesting (and unwanted) control dependencies on it.
            Add_Vertex
              (FA,
               Direct_Mapping_Id (End_Label (N)),
               Make_Aux_Vertex_Attributes (E_Loc     => N,
                                           Execution => Infinite_Loop),
               Faux_Exit_V);

            --  We now thread this at the back of the connection map
            --  for Statements (N). Sorry, this is really quite ugly.
            Linkup (FA,
                    CM (Union_Id (Statements (N))).Standard_Exits,
                    Faux_Exit_V);
            CM (Union_Id (Statements (N))).Standard_Exits :=
              Vertex_Sets.To_Set (Faux_Exit_V);

            --  Finally we add a mark the faux exit vertex as a
            --  possible exit of this loop.
            CM (Union_Id (N)).Standard_Exits.Include (Faux_Exit_V);
         end if;

         --  Loop the loop: V -> body -> V
         Linkup (FA, V, CM (Union_Id (Statements (N))).Standard_Entry);
         Linkup (FA, CM (Union_Id (Statements (N))).Standard_Exits, V);
      end Do_Loop;

      -------------------
      -- Do_While_Loop --
      -------------------

      procedure Do_While_Loop is
         V     : Flow_Graphs.Vertex_Id;
         Funcs : Node_Sets.Set;
      begin
         Collect_Functions_And_Read_Locked_POs
           (Condition (Iteration_Scheme (N)),
            Functions_Called   => Funcs,
            Tasking            => FA.Tasking,
            Include_Predicates => FA.Generating_Globals);

         Add_Vertex
           (FA,
            Direct_Mapping_Id (N),
            Make_Basic_Attributes
              (FA         => FA,
               Var_Ex_Use => Get_Variable_Set
                 (Condition (Iteration_Scheme (N)),
                  Scope                => FA.B_Scope,
                  Local_Constants      => FA.Local_Constants,
                  Fold_Functions       => True,
                  Use_Computed_Globals => not FA.Generating_Globals),
               Sub_Called => Funcs,
               Loops      => Ctx.Current_Loops,
               E_Loc      => N),
            V);
         Ctx.Folded_Function_Checks (N).Insert
           (Condition (Iteration_Scheme (N)));

         --  Flow for the while loops goes into the condition and then
         --  out again.
         CM (Union_Id (N)).Standard_Entry := V;
         CM (Union_Id (N)).Standard_Exits.Include (V);

         --  Loop the loop: V -> body -> V
         Linkup (FA, V, CM (Union_Id (Statements (N))).Standard_Entry);
         Linkup (FA, CM (Union_Id (Statements (N))).Standard_Exits, V);
      end Do_While_Loop;

      -----------------
      -- Do_For_Loop --
      -----------------

      procedure Do_For_Loop (Fully_Initialized : out Flow_Id_Sets.Set) is
         LPS : constant Node_Id :=
           Loop_Parameter_Specification (Iteration_Scheme (N));

         LP : constant Entity_Id := Defining_Identifier (LPS);

         DSD : constant Node_Id := Discrete_Subtype_Definition (LPS);

         R : constant Node_Id := Get_Loop_Range (N);
         V : Flow_Graphs.Vertex_Id;
         Funcs : Node_Sets.Set;
      begin
         --  We have a new variable here which we have not picked up
         --  in Create, so we should set it up.
         Create_Initial_And_Final_Vertices (LP, Variable_Kind, FA);

         --  Work out which of the three variants (empty, full,
         --  unknown) we have...
         if Is_Null_Range (Low_Bound (R), High_Bound (R)) then
            --  We have an empty range. We should complain!
            Add_Vertex
              (FA,
               Direct_Mapping_Id (N),
               Make_Basic_Attributes
                 (FA      => FA,
                  Var_Def => Flatten_Variable (LP, FA.B_Scope),
                  Loops   => Ctx.Current_Loops,
                  E_Loc   => N),
               V);

            --  Flow goes into and out of the loop. Note that we do
            --  NOT hook up the loop body.
            CM (Union_Id (N)).Standard_Entry := V;
            CM (Union_Id (N)).Standard_Exits.Include (V);

            Fully_Initialized := Flow_Id_Sets.Empty_Set;

         elsif Not_Null_Range (Low_Bound (R), High_Bound (R)) then
            --  We need to make sure the loop is executed at least once.

            Add_Vertex
              (FA,
               Direct_Mapping_Id (N),
               Make_Basic_Attributes
                 (FA      => FA,
                  Var_Def => Flatten_Variable (LP, FA.B_Scope),
                  Loops   => Ctx.Current_Loops,
                  E_Loc   => N),
               V);

            --  Flow goes into the first statement and out the loop vertex.
            CM (Union_Id (N)).Standard_Entry :=
              CM (Union_Id (Statements (N))).Standard_Entry;
            CM (Union_Id (N)).Standard_Exits.Include (V);

            --  Loop the loop: V -> body -> V
            Linkup (FA, V, CM (Union_Id (Statements (N))).Standard_Entry);
            Linkup (FA, CM (Union_Id (Statements (N))).Standard_Exits, V);

            Fully_Initialized := Variables_Initialized_By_Loop (N);

         else
            --  We don't know if the loop will be executed or not.
            Collect_Functions_And_Read_Locked_POs
              (DSD,
               Functions_Called   => Funcs,
               Tasking            => FA.Tasking,
               Include_Predicates => FA.Generating_Globals);

            Add_Vertex
              (FA,
               Direct_Mapping_Id (N),
               Make_Basic_Attributes
                 (FA         => FA,
                  Var_Def    => Flatten_Variable (LP, FA.B_Scope),
                  Var_Ex_Use => Get_Variable_Set
                    (DSD,
                     Scope                => FA.B_Scope,
                     Local_Constants      => FA.Local_Constants,
                     Fold_Functions       => True,
                     Use_Computed_Globals => not FA.Generating_Globals),
                  Sub_Called => Funcs,
                  Loops      => Ctx.Current_Loops,
                  E_Loc      => N),
               V);
            Ctx.Folded_Function_Checks (N).Insert (DSD);

            --  Flow for the conditional for loop is like a while
            --  loop.
            CM (Union_Id (N)).Standard_Entry := V;
            CM (Union_Id (N)).Standard_Exits.Include (V);

            --  Loop the loop: V -> body -> V
            Linkup (FA, V, CM (Union_Id (Statements (N))).Standard_Entry);
            Linkup (FA, CM (Union_Id (Statements (N))).Standard_Exits, V);

            Fully_Initialized := Flow_Id_Sets.Empty_Set;
         end if;
      end Do_For_Loop;

      ---------------------------
      -- Loop_Might_Exit_Early --
      ---------------------------

      function Loop_Might_Exit_Early (N : Node_Id) return Boolean
      is
         Contains_Abort : Boolean := False;

         function Proc_Search (N : Node_Id) return Traverse_Result;

         function Proc_Search (N : Node_Id) return Traverse_Result
         is
         begin
            case Nkind (N) is
               when N_Simple_Return_Statement   |
                    N_Extended_Return_Statement |
                    N_Exit_Statement            =>
                  Contains_Abort := True;
                  return Abandon;
               when others =>
                  return OK;
            end case;
         end Proc_Search;

         procedure Do_Search is new Traverse_Proc (Proc_Search);
      begin
         Do_Search (N);
         return Contains_Abort;
      end Loop_Might_Exit_Early;

      -----------------------------------
      -- Variables_Initialized_By_Loop --
      -----------------------------------

      function Variables_Initialized_By_Loop (N : Node_Id)
                                              return Flow_Id_Sets.Set
      is
         Fully_Initialized : Flow_Id_Sets.Set := Flow_Id_Sets.Empty_Set;

         type Target (Valid : Boolean := False)
            is record
               case Valid is
                  when True =>
                     Var : Flow_Id;
                     D   : Entity_Vectors.Vector;
                  when False =>
                     null;
               end case;
            end record;

         Null_Target : constant Target := (Valid => False);

         Current_Loop      : Node_Id         := Empty;
         Active_Loops      : Node_Sets.Set   := Node_Sets.Empty_Set;
         All_Loop_Vertices : Vertex_Sets.Set := Vertex_Sets.Empty_Set;

         Lc : constant Graph_Connections := CM (Union_Id (N));

         function Get_Array_Index (N : Node_Id) return Target;
         --  Convert the target of an assignment to an array into a flow id
         --  and a list of indices.

         function Fully_Defined_In_Original_Loop (T : Target) return Boolean
         with Pre => T.Valid;
         --  Performs a mini-flow analysis on the current loop fragment to
         --  see if T is defined on all paths (but not explicitly used).

         function Proc_Search (N : Node_Id) return Traverse_Result;
         --  In the traversal of the loop body, this finds suitable targets
         --  and checks if they are fully initialized.

         procedure Rec (N : Node_Id);
         --  Wrapper around the traversal, so that Proc_Search can call
         --  itself.

         ---------------------
         -- Get_Array_Index --
         ---------------------

         function Get_Array_Index (N : Node_Id) return Target is
            F : Flow_Id;
            T : Entity_Id;
            L : Entity_Vectors.Vector;
         begin
            --  First, is this really an array access?
            if Nkind (N) /= N_Indexed_Component then
               return Null_Target;
            end if;

            --  Does the Prefix chain only contain record fields?
            declare
               Ptr : Node_Id := Prefix (N);
            begin
               loop
                  case Nkind (Ptr) is
                     when N_Identifier | N_Expanded_Name =>
                        exit;
                     when N_Selected_Component =>
                        Ptr := Prefix (Ptr);
                     when others =>
                        return Null_Target;
                  end case;
               end loop;
            end;

            --  Construct the variable we're possibly fully defining.
            case Nkind (Prefix (N)) is
               when N_Identifier | N_Expanded_Name =>
                  F := Direct_Mapping_Id
                    (Unique_Entity (Entity (Prefix (N))));
                  T := Get_Type (Entity (Prefix (N)), FA.B_Scope);

               when N_Selected_Component =>
                  F := Record_Field_Id (Prefix (N));
                  T := Get_Type (Etype (Prefix (N)), FA.B_Scope);

               when others =>
                  raise Program_Error;
            end case;

            --  Extract indices (and make sure they are simple and
            --  distinct).
            L := Entity_Vectors.Empty_Vector;
            declare
               Ptr         : Node_Id := First (Expressions (N));
               Index_Ptr   : Node_Id := First_Index (T);
               Param_Range : Node_Id;
               Index_Range : Node_Id;
            begin
               while Present (Ptr) loop
                  case Nkind (Ptr) is
                     when N_Identifier | N_Expanded_Name =>
                        if L.Contains (Entity (Ptr)) then
                           --  Non-distinct entry, just abort. For
                           --  example:
                           --
                           --  for I in Idx loop
                           --     A (I, I) := 0;
                           --  end loop;
                           return Null_Target;
                        end if;

                        if not Active_Loops.Contains (Entity (Ptr)) then
                           --  Not a loop variable we care about, again
                           --  we just abort. For example:
                           --
                           --  for I in Idx loop
                           --     A (J) := 0;
                           --  end loop;
                           return Null_Target;
                        end if;

                        Param_Range := Get_Range (Entity (Ptr));
                        Index_Range := Get_Range (Index_Ptr);

                        --  ??? Do we need to do something here for
                        --      static_predicate?
                        if not
                          (Compile_Time_Compare (Low_Bound (Param_Range),
                                                 Low_Bound (Index_Range),
                                                 True) = EQ and then
                             Compile_Time_Compare (High_Bound (Param_Range),
                                                   High_Bound (Index_Range),
                                                   True) = EQ)
                        then
                           --  The loop parameter type does not fully
                           --  cover this index type.
                           return Null_Target;
                        end if;

                        L.Append (Entity (Ptr));

                     when others =>
                        --  This is not a simple entity, so just abort.
                        --  For example:
                        --
                        --  for I in Idx loop
                        --     A (I + 1) := 0;
                        --  end loop;
                        return Null_Target;
                  end case;

                  Next (Ptr);
                  Next_Index (Index_Ptr);
               end loop;
            end;

            return (Valid => True,
                    Var   => F,
                    D     => L);
         end Get_Array_Index;

         ------------------------------------
         -- Fully_Defined_In_Original_Loop --
         ------------------------------------

         function Fully_Defined_In_Original_Loop (T : Target) return Boolean is
            Fully_Defined : Boolean         := True;
            Touched       : Vertex_Sets.Set := Vertex_Sets.Empty_Set;

            procedure Check_Defined
              (V  : Flow_Graphs.Vertex_Id;
               Tv : out Flow_Graphs.Simple_Traversal_Instruction);
            --  Visitor to ensure all paths define T (and do not use it).

            procedure Check_Unused
              (V  : Flow_Graphs.Vertex_Id;
               Tv : out Flow_Graphs.Simple_Traversal_Instruction);
            --  Visitor to ensure all paths following a definition of T do
            --  not use it.

            procedure Check_Defined
              (V  : Flow_Graphs.Vertex_Id;
               Tv : out Flow_Graphs.Simple_Traversal_Instruction)
            is
               F : constant Flow_Id      := FA.CFG.Get_Key (V);
               A : constant V_Attributes := FA.Atr (V);
            begin
               Touched.Include (V);

               if A.Variables_Explicitly_Used.Contains (T.Var) then
                  Fully_Defined := False;
                  Tv            := Flow_Graphs.Abort_Traversal;

               elsif A.Variables_Defined.Contains (T.Var) and then
                 F.Kind = Direct_Mapping and then
                 Present (F.Node) and then
                 Nkind (F.Node) = N_Assignment_Statement and then
                 Get_Array_Index (Name (F.Node)) = T
               then
                  FA.CFG.DFS (Start         => V,
                              Include_Start => False,
                              Visitor       => Check_Unused'Access);
                  if Fully_Defined then
                     Tv := Flow_Graphs.Skip_Children;
                  else
                     Tv := Flow_Graphs.Abort_Traversal;
                  end if;

               elsif Lc.Standard_Exits.Contains (V) then
                  Fully_Defined := False;
                  Tv            := Flow_Graphs.Abort_Traversal;

               else
                  Tv := Flow_Graphs.Continue;
               end if;
            end Check_Defined;

            procedure Check_Unused
              (V  : Flow_Graphs.Vertex_Id;
               Tv : out Flow_Graphs.Simple_Traversal_Instruction)
            is
               --  F : constant Flow_Id      := FA.CFG.Get_Key (V);
               A : constant V_Attributes := FA.Atr (V);
            begin
               if Touched.Contains (V) then
                  Tv := Flow_Graphs.Skip_Children;
               elsif A.Variables_Explicitly_Used.Contains (T.Var) then
                  Fully_Defined := False;
                  Tv            := Flow_Graphs.Abort_Traversal;
               else
                  Tv := Flow_Graphs.Continue;
               end if;
            end Check_Unused;

         begin
            FA.CFG.DFS (Start         => Lc.Standard_Entry,
                        Include_Start => True,
                        Visitor       => Check_Defined'Access);

            return Fully_Defined;
         end Fully_Defined_In_Original_Loop;

         -----------------
         -- Proc_Search --
         -----------------

         function Proc_Search (N : Node_Id) return Traverse_Result is
         begin
            case Nkind (N) is
               when N_Loop_Statement =>
                  declare
                     Old_Loop : constant Node_Id := Current_Loop;
                  begin
                     if N = Current_Loop then
                        return OK;

                     elsif Is_For_Loop (N) then
                        Current_Loop := N;
                        Active_Loops.Insert (Get_Loop_Variable (N));

                        Rec (N);

                        Current_Loop := Old_Loop;
                        Active_Loops.Delete (Get_Loop_Variable (N));

                        return Skip;
                     end if;
                  end;

               when N_Assignment_Statement =>
                  declare
                     T : constant Target := Get_Array_Index (Name (N));
                  begin
                     if T.Valid
                       and then Fully_Defined_In_Original_Loop (T)
                     then
                        Fully_Initialized.Include (T.Var);
                     end if;
                  end;

               when N_Procedure_Call_Statement =>
                  --  ??? not done yet, we can implement this on demand

                  --  all out parameters (globals not relevant here)
                  null;

               when others =>
                  null;
            end case;
            return OK;
         end Proc_Search;

         procedure Rec_Inner is new Traverse_Proc (Proc_Search);

         ---------
         -- Rec --
         ---------

         procedure Rec (N : Node_Id) is
         begin
            Rec_Inner (N);
         end Rec;

      --  Start of processing for Variables_Initialized_By_Loop

      begin
         if Loop_Might_Exit_Early (N) then
            return Flow_Id_Sets.Empty_Set;
         end if;

         for V of FA.CFG.Get_Collection (Flow_Graphs.All_Vertices) loop
            if FA.Atr (V).Loops.Contains (Get_Loop_Name (N)) then
               All_Loop_Vertices.Insert (V);
            end if;
         end loop;

         Rec (N);
         return Fully_Initialized;
      end Variables_Initialized_By_Loop;

      ----------------------
      -- Do_Iterator_Loop --
      ----------------------

      procedure Do_Iterator_Loop is
         I_Spec : constant Node_Id :=
           Iterator_Specification (Iteration_Scheme (N));

         Param : constant Entity_Id := Defining_Identifier (I_Spec);
         Cont  : constant Node_Id   := Name (I_Spec);

         V : Flow_Graphs.Vertex_Id;
         Funcs : Node_Sets.Set;
      begin
         --  Set up parameter variable.
         Create_Initial_And_Final_Vertices (Param, Variable_Kind, FA);

         --  Create vertex for the container expression. We also define the
         --  loop parameter here.
         Collect_Functions_And_Read_Locked_POs
           (Cont,
            Functions_Called   => Funcs,
            Tasking            => FA.Tasking,
            Include_Predicates => FA.Generating_Globals);

         Add_Vertex
           (FA,
            Direct_Mapping_Id (N),
            Make_Basic_Attributes
              (FA         => FA,
               Var_Def    => Flatten_Variable (Param, FA.B_Scope),
               Var_Ex_Use => Get_Variable_Set
                 (Cont,
                  Scope                => FA.B_Scope,
                  Local_Constants      => FA.Local_Constants,
                  Fold_Functions       => True,
                  Use_Computed_Globals => not FA.Generating_Globals),
               Sub_Called => Funcs,
               Loops      => Ctx.Current_Loops,
               E_Loc      => Cont),
            V);
         Ctx.Folded_Function_Checks (N).Insert (Cont);

         --  Pretty normal flow (see while loops)
         CM (Union_Id (N)) := Trivial_Connection (V);

         --  Loop the loop: V -> body -> V
         Linkup (FA, V, CM (Union_Id (Statements (N))).Standard_Entry);
         Linkup (FA, CM (Union_Id (Statements (N))).Standard_Exits, V);
      end Do_Iterator_Loop;

      I_Scheme          : constant Node_Id   := Iteration_Scheme (N);
      Loop_Id           : constant Entity_Id := Entity (Identifier (N));
      Fully_Initialized : Flow_Id_Sets.Set   := Flow_Id_Sets.Empty_Set;

   --  Start of processing for Do_Loop_Statement

   begin
      --  Start with a blank slate for the loops entry and exit.
      CM.Include (Union_Id (N), No_Connections);

      --  Construct graph for the loop body. Please note that early
      --  exists may already change the above, so be sure to only use
      --  union or include, instead of setting the standard exits.
      --
      --  We also change the context to include the current
      --  loop. Please note that we don't flag the loop statement
      --  itself as part of the loop, hence the corresponding delete
      --  is here as well.
      FA.Loops.Insert (Loop_Id);
      Ctx.Current_Loops.Insert (Loop_Id);
      Ctx.Entry_References.Include (Loop_Id, Node_Sets.Empty_Set);

      declare
         Tmp : constant Entity_Id := Ctx.Active_Loop;
      begin
         --  We can't use 'Update here as we may modify Ctx.
         Ctx.Active_Loop := Loop_Id;
         Process_Statement_List (Statements (N), FA, CM, Ctx);
         Ctx.Active_Loop := Tmp;
      end;

      if No (I_Scheme) then
         --  We have a general (possibly infinite) loop.
         Do_Loop;

      elsif Present (Condition (I_Scheme)) then
         --  We have a while loop.
         Do_While_Loop;

      elsif Present (Loop_Parameter_Specification (I_Scheme)) then
         --  This is a normal for loop over a type or range.
         Do_For_Loop (Fully_Initialized);

      elsif Present (Iterator_Specification (I_Scheme)) then
         --  This is a `in' or `of' loop over some container.
         Do_Iterator_Loop;

      else
         raise Program_Error;
      end if;

      --  If we need an init vertex, we add it before the loop itself.
      if not Fully_Initialized.Is_Empty then
         declare
            V : Flow_Graphs.Vertex_Id;
         begin
            Add_Vertex
              (FA,
               Make_Basic_Attributes
                 (FA         => FA,
                  Var_Def    => Fully_Initialized,
                  Loops      => Ctx.Current_Loops,
                  E_Loc      => Loop_Id,
                  Print_Hint => Pretty_Print_Loop_Init)'
                 Update (Is_Program_Node => False),
               V);

            Linkup (FA, V, CM (Union_Id (N)).Standard_Entry);
            CM (Union_Id (N)).Standard_Entry := V;
         end;
      end if;

      --  Now we need to glue the 'loop_entry checks to the front of
      --  the loop.
      declare
         Augmented_Loop : Union_Lists.List := Union_Lists.Empty_List;
         V              : Flow_Graphs.Vertex_Id;
         Block          : Graph_Connections;
      begin
         --  We stick all loop entry references on a list of nodes.
         for Reference of Ctx.Entry_References (Loop_Id) loop
            Add_Vertex
              (FA,
               Direct_Mapping_Id (Reference),
               Make_Sink_Vertex_Attributes
                 (FA            => FA,
                  Var_Use       => Get_Variable_Set
                    (Prefix (Reference),
                     Scope                => FA.B_Scope,
                     Local_Constants      => FA.Local_Constants,
                     Fold_Functions       => False,
                     Use_Computed_Globals => not FA.Generating_Globals),
                  Is_Loop_Entry => True),
               V);
            Ctx.Folded_Function_Checks (N).Insert (Prefix (Reference));

            CM.Include
              (Union_Id (Reference),
               Trivial_Connection (V));

            Augmented_Loop.Append (Union_Id (Reference));
         end loop;

         --  Then we stick the actual loop at the end.
         Augmented_Loop.Append (Union_Id (N));

         --  And connect up the dots, and finally replacing the
         --  connection map we have for N with the new augmented one.
         Join (FA    => FA,
               CM    => CM,
               Nodes => Augmented_Loop,
               Block => Block);
         CM (Union_Id (N)) := Block;
      end;

      Ctx.Current_Loops.Delete (Loop_Id);

      --  Finally, we can update the loop information in Flow_Utility.

      Add_Loop (Loop_Id);
      for V of FA.CFG.Get_Collection (Flow_Graphs.All_Vertices) loop
         if FA.Atr (V).Loops.Contains (Loop_Id) then
            declare
               Combined_Writes : constant Flow_Id_Sets.Set :=
                 FA.Atr (V).Variables_Defined or FA.Atr (V).Volatiles_Read;
            begin
               for F of Combined_Writes loop
                  Add_Loop_Write (Loop_Id, F);
               end loop;
            end;
         end if;
      end loop;

   end Do_Loop_Statement;

   ----------------------------------
   --  Do_Null_Or_Raise_Statement  --
   ----------------------------------

   procedure Do_Null_Or_Raise_Statement
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
   is
      pragma Unreferenced (Ctx);
      V : Flow_Graphs.Vertex_Id;
   begin
      --  We introduce a vertex V which has control entering from the top and
      --  leaving from the bottom.
      Add_Vertex
        (FA,
         Direct_Mapping_Id (N),
         Make_Aux_Vertex_Attributes
           (E_Loc     => N,
            Execution => (if Nkind (N) in N_Raise_Statement | N_Raise_xxx_Error
                          then Abnormal_Termination
                          else Normal_Execution)),
         V);
      CM.Include (Union_Id (N), Trivial_Connection (V));
   end Do_Null_Or_Raise_Statement;

   -----------------------------
   --  Do_Object_Declaration  --
   -----------------------------

   procedure Do_Object_Declaration
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
   is
      V     : Flow_Graphs.Vertex_Id;
      Inits : Vertex_Vectors.Vector := Vertex_Vectors.Empty_Vector;
      FS    : Flow_Id_Sets.Set;
      To_Cw : Boolean;

      Is_Constant : constant Boolean := Nkind (N) = N_Object_Declaration
                                        and then Constant_Present (N);

      Object_Name : constant Entity_Name :=
        To_Entity_Name (Defining_Identifier (N));

      procedure Find_Tasks (T : Entity_Id; Array_Component : Boolean)
        with Pre => Is_Type (T);
      --  Update the map with number of task instances.
      --
      --  It checks which and how many tasks are instantiated when an object of
      --  type T is declared. Flag Array_Component should be True if the parent
      --  type is an array with possibly more than one element.
      --
      --  This procedure mirrors Count_Tasks from
      --  Sem_Ch3.Analyze_Object_Declaration.

      ----------------
      -- Find_Tasks --
      ----------------

      procedure Find_Tasks (T : Entity_Id; Array_Component : Boolean) is
         C : Entity_Id;
         X : Node_Id;

         type Array_Elements is (Zero, One, Many);
         --  Type for checking the number of elements in an array

         S : Array_Elements;
         --  Number of elements in the array

      begin
         if not Has_Task (T) then
            return;

         elsif Is_Task_Type (T) then
            declare
               --  For discriminated tasks record the number of instances of
               --  the base type.
               TN : constant Entity_Name := To_Entity_Name (Etype (T));
            begin
               Register_Task_Object
                 (Type_Name => TN,
                  Object => (Name => Object_Name,
                             Instances =>
                               (if Array_Component
                                then Many
                                else One),
                             Node => N));
            end;

         elsif Is_Record_Type (T) then
            --  Ignore record variants and simply find any task components
            C := First_Component (T);
            while Present (C) loop
               Find_Tasks (Etype (C), Array_Component);
               Next_Component (C);
            end loop;

         elsif Is_Array_Type (T) then
            --  Check whether the array is empty (at least one index range
            --  statically equal zero) or has exectly one component (all ranges
            --  statically equal one); otherwise assume it has many components.
            S := One;
            X := First_Index (T);

            while Present (X) loop
               C := Etype (X);

               if not Is_OK_Static_Subtype (C) then
                  S := Many;
               else
                  declare
                     Length : constant Uint :=
                       (UI_Max (Uint_0,
                        Expr_Value (Type_High_Bound (C)) -
                          Expr_Value (Type_Low_Bound (C)) + Uint_1));
                  begin
                     if Length = Uint_0 then
                        S := Zero;
                        exit;
                     elsif Length = Uint_1 then
                        null;
                     else
                        S := Many;
                     end if;
                  end;
               end if;

               Next_Index (X);
            end loop;

            if S = Zero then
               null;
            else
               Find_Tasks (Component_Type (T),
                           Array_Component => S = Many);
            end if;
         end if;
      end Find_Tasks;

   --  Start of processing for Do_Object_Declaration

   begin
      --  We are dealing with a local constant. These constants are *not*
      --  ignored.
      if Is_Constant then
         if Present (Expression (N))
           or else Is_Imported (Defining_Identifier (N))
         then
            FA.Local_Constants.Include (Defining_Identifier (N));
         else
            --  This is a deferred constant. We ignore it - we will deal
            --  with it once we get to the actual constant.
            --
            --  ??? What should we do if the private part is not in SPARK?
            Add_Vertex (FA,
                        Direct_Mapping_Id (N),
                        Null_Node_Attributes,
                        V);
            CM.Include (Union_Id (N), Trivial_Connection (V));
            return;
         end if;
      end if;

      --  First, we need a 'initial and 'final vertex for this object. We only
      --  create these if we are not dealing with a Part_Of a single concurrent
      --  type.
      if not Is_Part_Of_Concurrent_Object (Defining_Identifier (N)) then
         Create_Initial_And_Final_Vertices (Defining_Identifier (N),
                                            Variable_Kind,
                                            FA);
      end if;

      if No (Expression (N)) then
         --  No initializing expression, so we fall back to the
         --  default initialization (if any).
         FS := Flatten_Variable (Defining_Identifier (N), FA.B_Scope);

         for F of FS loop
            if Is_Default_Initialized (F) then
               Add_Vertex
                 (FA,
                  Make_Default_Initialization_Attributes
                    (FA    => FA,
                     Scope => FA.B_Scope,
                     F     => F,
                     Loops => Ctx.Current_Loops),
                  V);
               Inits.Append (V);
            end if;
         end loop;

         if Inits.Length = 0 then
            --  We did not have anything with a default initial value,
            --  so we just create a null vertex here.
            Add_Vertex (FA,
                        Direct_Mapping_Id (N),
                        Null_Node_Attributes,
                        V);
            Inits.Append (V);
         end if;

      else
         --  We have a variable declaration with an initialization.
         To_Cw :=
           Is_Class_Wide_Type (Get_Type (Defining_Identifier (N), FA.B_Scope))
             and then
           not Is_Class_Wide_Type (Get_Type (Expression (N), FA.B_Scope));

         declare
            Var_Def : Flow_Id_Sets.Set := Flow_Id_Sets.Empty_Set;
            Funcs   : Node_Sets.Set;
         begin
            FS := Flatten_Variable (Defining_Identifier (N), FA.B_Scope);
            for F of FS loop
               Var_Def.Include (F);
               if Has_Bounds (F, FA.B_Scope) then
                  Var_Def.Include (F'Update (Facet => The_Bounds));
               end if;
            end loop;

            if RHS_Split_Useful (N, FA.B_Scope) then

               declare
                  M : constant Flow_Id_Maps.Map := Untangle_Record_Assignment
                    (N                            => Expression (N),
                     Map_Root                     =>
                       Direct_Mapping_Id (Defining_Identifier (N)),
                     Map_Type                     =>
                       Get_Type (Defining_Identifier (N), FA.B_Scope),
                     Scope                        => FA.B_Scope,
                     Local_Constants              => FA.Local_Constants,
                     Fold_Functions               => True,
                     Use_Computed_Globals         => not FA.Generating_Globals,
                     Expand_Synthesized_Constants => False);

                  Output       : Flow_Id;
                  Inputs       : Flow_Id_Sets.Set;
                  All_Vertices : Vertex_Sets.Set  := Vertex_Sets.Empty_Set;
                  Missing      : Flow_Id_Sets.Set := Var_Def;
               begin
                  Collect_Functions_And_Read_Locked_POs
                    (Expression (N),
                     Functions_Called   => Funcs,
                     Tasking            => FA.Tasking,
                     Include_Predicates => FA.Generating_Globals);

                  for C in M.Iterate loop
                     Output := Flow_Id_Maps.Key (C);
                     Inputs := Flow_Id_Maps.Element (C);

                     --  ??? It might be useful to improve E_Loc to point
                     --      at the relevant bit in the aggregate.

                     Add_Vertex
                       (FA,
                        Make_Basic_Attributes
                          (FA         => FA,
                           Var_Def    => Flow_Id_Sets.To_Set (Output),
                           Var_Ex_Use => Inputs,
                           Sub_Called => Funcs,
                           Loops      => Ctx.Current_Loops,
                           E_Loc      => N,
                           Print_Hint => Pretty_Print_Record_Field),
                        V);
                     Missing.Delete (Output);

                     Inits.Append (V);
                     All_Vertices.Insert (V);
                  end loop;

                  --  Any "missing" fields which are produced by flatten,
                  --  but not by URA we flag as initialized to the empty
                  --  set; since it is not possible in SPARK to partially
                  --  initialize a variable at declaration.
                  for F of Missing loop
                     Add_Vertex
                       (FA,
                        Make_Basic_Attributes
                          (FA         => FA,
                           Var_Def    => Flow_Id_Sets.To_Set (F),
                           Var_Ex_Use => Flow_Id_Sets.Empty_Set,
                           Sub_Called => Node_Sets.Empty_Set,
                           Loops      => Ctx.Current_Loops,
                           E_Loc      => N,
                           Print_Hint => Pretty_Print_Record_Field),
                        V);
                     Inits.Append (V);
                     All_Vertices.Insert (V);
                  end loop;

                  declare
                     C : Flow_Graphs.Cluster_Id;
                  begin
                     FA.CFG.New_Cluster (C);
                     for V of All_Vertices loop
                        FA.Other_Fields.Insert
                          (V,
                           All_Vertices - Vertex_Sets.To_Set (V));
                        FA.CFG.Set_Cluster (V, C);
                     end loop;
                  end;
               end;

            else
               Collect_Functions_And_Read_Locked_POs
                 (Expression (N),
                  Functions_Called   => Funcs,
                  Tasking            => FA.Tasking,
                  Include_Predicates => FA.Generating_Globals);

               Add_Vertex
                 (FA,
                  Direct_Mapping_Id (N),
                  Make_Basic_Attributes
                    (FA         => FA,
                     Var_Def    => Var_Def,
                     Var_Ex_Use => Get_Variable_Set
                       (Expression (N),
                        Scope                => FA.B_Scope,
                        Local_Constants      => FA.Local_Constants,
                        Fold_Functions       => True,
                        Use_Computed_Globals => not FA.Generating_Globals,
                        Consider_Extensions  => To_Cw),
                     Sub_Called => Funcs,
                     Loops      => Ctx.Current_Loops,
                     E_Loc      => N),
                  V);
               Inits.Append (V);

            end if;

            Ctx.Folded_Function_Checks (N).Include (Expression (N));
         end;
      end if;

      --  If this type has a Default_Initial_Condition then we need to
      --  create a vertex to check for uninitialized variables within the
      --  Default_Initial_Condition's expression.
      declare
         Typ  : constant Node_Id := Etype (Defining_Identifier (N));
         Expr : Node_Id;

         Variables_Used       : Flow_Id_Sets.Set := Flow_Id_Sets.Empty_Set;
         Components_Of_Type   : Flow_Id_Sets.Set := Flow_Id_Sets.Empty_Set;
         Components_Of_Object : Flow_Id_Sets.Set := Flow_Id_Sets.Empty_Set;

         Funcs : Node_Sets.Set;
      begin
         if (Has_Default_Init_Cond (Typ)
               or else Has_Inherited_Default_Init_Cond (Typ))
           and then Present (Default_Init_Cond_Procedure (Typ))
         then
            Expr := Get_Expr_From_Check_Only_Proc
              (Default_Init_Cond_Procedure (Typ));

            if Present (Expr) then
               --  Note that default initial conditions can make use of
               --  the type mark. For example
               --
               --     type T is private
               --       with Default_Initial_Condition => Foo (T) > 2;
               --
               --  When an object of that type is later declared
               --
               --     X : T;
               --
               --  we need to replace all occurrences of T with X (and
               --  all components of T with all components of X)
               --  to produce the correct default initial condition.
               Variables_Used := Get_Variable_Set
                 (Expr,
                  Scope                => FA.B_Scope,
                  Local_Constants      => FA.Local_Constants,
                  Fold_Functions       => True,
                  Use_Computed_Globals => not FA.Generating_Globals);

               --  Calculate components of Type and Object
               Components_Of_Type   :=
                 Flatten_Variable (First_Entity
                                     (Default_Init_Cond_Procedure (Typ)),
                                   FA.B_Scope);
               Components_Of_Object :=
                 Flatten_Variable (Defining_Identifier (N), FA.B_Scope);

               --  Replace components if needed
               if (for some Comp of Components_Of_Type =>
                     Variables_Used.Contains (Comp))
               then
                  Variables_Used := Variables_Used - Components_Of_Type;
                  Variables_Used.Union (Components_Of_Object);
               end if;

               Collect_Functions_And_Read_Locked_POs
                 (Expr,
                  Functions_Called   => Funcs,
                  Tasking            => FA.Tasking,
                  Include_Predicates => FA.Generating_Globals);

               Add_Vertex
                 (FA,
                  Make_Sink_Vertex_Attributes
                    (FA         => FA,
                     Var_Use    => Replace_Flow_Ids
                       (Of_This   => First_Entity
                                       (Default_Init_Cond_Procedure (Typ)),
                        With_This => Defining_Identifier (N),
                        The_Set   => Variables_Used),
                     Sub_Called => Funcs,
                     Is_Proof   => True,
                     Is_DIC     => True,
                     E_Loc      => N),
                  V);
               Inits.Append (V);

               --  Check for folded functions
               Ctx.Folded_Function_Checks (N).Include (Expr);
            end if;
         end if;
      end;

      if Inits.Is_Empty then
         --  For some null records, nothing might happen, so we create a
         --  dummy vertex.
         Add_Vertex (FA,
                     Direct_Mapping_Id (N),
                     Null_Node_Attributes,
                     V);
         Inits.Append (V);
      end if;

      V := Flow_Graphs.Null_Vertex;
      for W of Inits loop
         if V /= Flow_Graphs.Null_Vertex then
            Linkup (FA, V, W);
         end if;
         V := W;
      end loop;
      CM.Include (Union_Id (N),
                  Graph_Connections'
                    (Standard_Entry => Inits.First_Element,
                     Standard_Exits => To_Set (Inits.Last_Element)));

      if Ekind (FA.Analyzed_Entity) in E_Package | E_Package_Body then
         --  If we are analyzing a package body or spec and we just
         --  introduced 'Initial and 'Final vertices for an entity
         --  that is mentioned in an initializes aspect, we have
         --  to set Is_Export on the corresponding 'Final vertices.
         FS := Flatten_Variable (Defining_Identifier (N), FA.B_Scope);

         for F of FS loop
            declare
               Final_F_Id : constant Flow_Id :=
                 Change_Variant (F, Final_Value);

               Final_V_Id : constant Flow_Graphs.Vertex_Id :=
                 FA.CFG.Get_Vertex (Final_F_Id);
            begin
               if Final_V_Id /= Flow_Graphs.Null_Vertex then
                  declare
                     Final_Atr : V_Attributes := FA.Atr (Final_V_Id);

                     Entire_Var : constant Entity_Id := Final_F_Id.Node;
                  begin
                     Final_Atr.Is_Export := Final_Atr.Is_Export
                       or else Is_Initialized_At_Elaboration (Entire_Var,
                                                              FA.B_Scope);

                     FA.Atr (Final_V_Id) := Final_Atr;
                  end;
               end if;
            end;
         end loop;

         --  In phase 1 we count task instances (which can be only declared at
         --  library level because of the Ravenscar profile restrictions).
         if FA.Generating_Globals then
            --  Register task objects
            Find_Tasks (Etype (Defining_Identifier (N)),
                        Array_Component => False);
         end if;
      end if;
   end Do_Object_Declaration;

   ----------------------------
   -- Do_Package_Declaration --
   ----------------------------

   procedure Do_Package_Declaration
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
   is
      AS_Pragma   : constant Node_Id :=
        Get_Pragma (Defining_Unit_Name (Specification (N)),
                    Pragma_Abstract_State);

      Init_Pragma : constant Node_Id :=
        Get_Pragma (Defining_Unit_Name (Specification (N)),
                    Pragma_Initializes);
   begin

      --  Introduce variables from the abstract state of the nested
      --  package.

      if Present (AS_Pragma) then
         declare
            PAA : Node_Id;
            AS  : Node_Id;
         begin
            PAA := First (Pragma_Argument_Associations (AS_Pragma));
            AS := First (Expressions (Expression (PAA)));
            while Present (AS) loop
               --  Creating 'Initial and 'Final vertices for every
               --  state abstraction and setting Is_Export to True
               --  if the corresponding entity is initialized.
               declare
                  New_E : constant Entity_Id :=
                    (if Nkind (AS) = N_Extension_Aggregate then
                       Entity (Ancestor_Part (AS))
                     else
                       Entity (AS));

                  Final_F_Id : constant Flow_Id :=
                    Change_Variant (Direct_Mapping_Id (New_E),
                                    Final_Value);

                  Final_V_Id : Flow_Graphs.Vertex_Id :=
                    FA.CFG.Get_Vertex (Final_F_Id);
               begin
                  --  Both the Refined_State aspect of the
                  --  Analyzed_Entity and the Abstract_State aspect of
                  --  the nested packages add vertices for state
                  --  abstractions so we have to be careful not to
                  --  add something that already exists.
                  if Final_V_Id = Flow_Graphs.Null_Vertex then

                     Create_Initial_And_Final_Vertices
                       (New_E, Variable_Kind, FA);

                     Final_V_Id := FA.CFG.Get_Vertex (Final_F_Id);

                     if Ekind (FA.Analyzed_Entity) in E_Package |
                                                      E_Package_Body
                     then
                        declare
                           Final_Atr  : V_Attributes := FA.Atr (Final_V_Id);
                        begin
                           Final_Atr.Is_Export := Final_Atr.Is_Export
                             or else Is_Initialized_At_Elaboration
                                       (New_E,
                                        FA.B_Scope);

                           FA.Atr (Final_V_Id) := Final_Atr;
                        end;
                     end if;
                  end if;
               end;

               Next (AS);
            end loop;
         end;
      end if;

      --  Traverse visible and private part of the specs and link them up.

      declare
         Visible_Decls : constant List_Id :=
           Visible_Declarations (Specification (N));

         Private_Decls : constant List_Id :=
           Private_Declarations (Specification (N));
      begin
         Process_Statement_List (Visible_Decls, FA, CM, Ctx);

         if No (Init_Pragma)
           and then Present (Private_Decls)
           and then (No (SPARK_Aux_Pragma (Defining_Entity (N)))
                       or else Get_SPARK_Mode_From_Pragma
                               (SPARK_Aux_Pragma (Defining_Entity (N))) /= Off)
         then
            --  We only process the private declarations if there is no
            --  initializes pragma and if the private declarations are
            --  actually in SPARK.
            Process_Statement_List (Private_Decls, FA, CM, Ctx);

            --  Link the visible declarations to the private declarations
            Linkup
              (FA,
               CM (Union_Id (Visible_Decls)).Standard_Exits,
               CM (Union_Id (Private_Decls)).Standard_Entry);

            --  The standard entry of N is the entry to the visible
            --  declarations and the standard exits are the exits of the
            --  private declarations.
            CM.Include
              (Union_Id (N),
               Graph_Connections'
                 (Standard_Entry => CM.Element
                    (Union_Id (Visible_Decls)).Standard_Entry,
                  Standard_Exits => CM.Element
                    (Union_Id (Private_Decls)).Standard_Exits));
         else
            --  We have only processed the visible declarations so we just copy
            --  the connections of N from Visible_Decls.
            Copy_Connections (CM,
                              Dst => Union_Id (N),
                              Src => Union_Id (Visible_Decls));
         end if;
      end;

   end Do_Package_Declaration;

   -----------------------------
   -- Do_Package_Body_Or_Stub --
   -----------------------------

   procedure Do_Package_Body_Or_Stub
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
   is
      function Find_Node (E : Entity_Id) return Node_Id
        with Post => Nkind (Find_Node'Result) in
                       N_Defining_Identifier  |
                       N_Identifier           |
                       N_Expanded_Name        |
                       N_Component_Association;
      --  Looks through the initializes aspect on FA.Analyzed_Entity
      --  and returns the node which represents the
      --  initialization_item where E is the LHS.
      --
      --  In the case of
      --     Initializes => (X,
      --  we return the node for X (N_Identifier | N_Expanded_Name).
      --
      --  In the case of
      --     Initializes => (X => Y
      --  we return the node for => (N_Component_Association).

      function Get_Declarations return List_Id;
      --  Returns the List_Id that corresponds to the body's declarations.

      Package_Spec : constant Entity_Id :=
        (case Nkind (N) is
         when N_Package_Body      => Corresponding_Spec (N),
         when N_Package_Body_Stub => Corresponding_Spec_Of_Stub (N),
         when others              => raise Program_Error);

      Abstract_State_Aspect : constant Node_Id :=
        Get_Pragma (Package_Spec,
                    Pragma_Abstract_State);

      Initializes_Aspect : constant Node_Id := Get_Pragma (Package_Spec,
                                                           Pragma_Initializes);

      Pkg_Body : constant Node_Id :=
        (case Nkind (N) is
         when N_Package_Body      => N,
         when N_Package_Body_Stub => Parent (Corresponding_Body (N)),
         when others              => raise Program_Error);

      Initializes_Scope : constant Flow_Scope :=
        (case Nkind (N) is
         when N_Package_Body      => Get_Enclosing_Body_Flow_Scope
                                       (Get_Flow_Scope (Pkg_Body)),
         when N_Package_Body_Stub => Get_Flow_Scope
                                       (Get_Body_Or_Stub (Pkg_Body)),
         when others              => raise Program_Error);
      --  The above holds the scope of the nested package. In the case of a
      --  stub we look at where the stub is placed instead.

      DM : constant Dependency_Maps.Map :=
        Parse_Initializes (Initializes_Aspect,
                           Package_Spec,
                           Initializes_Scope);

      ---------------
      -- Find_Node --
      ---------------

      function Find_Node (E : Entity_Id) return Node_Id is
         F : Flow_Id;
         N : Node_Id;
      begin
         for Initialized_Var in DM.Iterate loop
            F := Dependency_Maps.Key (Initialized_Var);
            N := (if F.Kind in Direct_Mapping | Record_Field
                  then Get_Direct_Mapping_Id (F)
                  else Empty);

            if N = E then
               return N;
            end if;
         end loop;

         --  We should never reach here!
         raise Program_Error;
      end Find_Node;

      ----------------------
      -- Get_Declarations --
      ----------------------

      function Get_Declarations return List_Id is (Declarations (Pkg_Body));

      V : Flow_Graphs.Vertex_Id;

   begin

      if Nkind (Parent (Parent (Package_Spec))) = N_Generic_Package_Declaration
        and then not Is_Generic_Instance (Package_Spec)
      then
         --  We skip generic package bodies that do not belong to
         --  instantiations.
         Add_Vertex (FA, Direct_Mapping_Id (N), Null_Node_Attributes, V);
         CM.Include (Union_Id (N), Trivial_Connection (V));
         return;
      end if;

      if (Present (Abstract_State_Aspect) and then DM.Is_Empty)
        or else (DM.Is_Empty
                   and then not Entity_Body_In_SPARK (Package_Spec))
      then
         --  We create a null vertex when:
         --
         --    1) we have an Abstract_State aspect and no state is
         --       initialized (then the package elaboration will have no
         --       observable effect on the enclosing package)
         --
         --    2) no state is initialized and the body of the package is not
         --       in SPARK.

         Add_Vertex (FA, Direct_Mapping_Id (N), Null_Node_Attributes, V);
         CM.Include (Union_Id (N), Trivial_Connection (V));
         return;
      end if;

      if No (Abstract_State_Aspect)
        and then Entity_Body_In_SPARK (Package_Spec)
      then
         --  Traverse package body declarations.
         declare
            Body_Declarations : constant List_Id := Get_Declarations;
         begin
            Process_Statement_List (Body_Declarations, FA, CM, Ctx);

            Copy_Connections (CM,
                              Dst => Union_Id (N),
                              Src => Union_Id (Body_Declarations));
         end;
      end if;

      if not DM.Is_Empty then
         --  When we encounter the package body (or its stub) and
         --  after we have created vertices for the variables in the
         --  body's declarations, we know that the package has been
         --  elaborated. We need to apply the Initializes aspect at
         --  this point.

         declare
            Verts          : Union_Lists.List := Union_Lists.Empty_List;
            Initializes_CM : Graph_Connections;
         begin
            for C in DM.Iterate loop
               declare
                  The_Out : constant Flow_Id := Dependency_Maps.Key (C);
                  The_Ins : constant Flow_Id_Sets.Set :=
                    Dependency_Maps.Element (C);

                  Init_Item : constant Node_Id :=
                    Find_Node (Get_Direct_Mapping_Id (The_Out));
               begin
                  Verts.Append (Union_Id (Init_Item));

                  Add_Vertex
                    (FA,
                     Direct_Mapping_Id (Init_Item),
                     Make_Package_Initialization_Attributes
                       (FA        => FA,
                        The_State => The_Out,
                        Inputs    => The_Ins,
                        Scope     => FA.B_Scope,
                        Loops     => Ctx.Current_Loops,
                        E_Loc     => Init_Item),
                     V);
                  CM.Include (Union_Id (Init_Item),
                              Trivial_Connection (V));
               end;
            end loop;

            Join (FA    => FA,
                  CM    => CM,
                  Nodes => Verts,
                  Block => Initializes_CM);

            if No (Abstract_State_Aspect)
              and then Entity_Body_In_SPARK (Package_Spec)
            then
               declare
                  Body_Declarations : constant List_Id := Get_Declarations;
               begin
                  --  We connect the Declarations of the body to the
                  --  Initializes_CM.
                  Linkup
                    (FA,
                     CM (Union_Id (Body_Declarations)).Standard_Exits,
                     CM (Verts.First_Element).Standard_Entry);

                  --  We set the standard entry of N to the standard
                  --  entry of the body's declarations and the
                  --  standard exists of N to the standard exists of
                  --  the last element in the Verts union list.
                  CM.Include
                    (Union_Id (N),
                     Graph_Connections'
                       (Standard_Entry => CM.Element
                          (Union_Id (Body_Declarations)).Standard_Entry,
                        Standard_Exits => CM.Element
                          (Verts.Last_Element).Standard_Exits));
               end;
            else
               --  Since we do not process any declarations all we
               --  have to do is to connect N to the Initializes_CM.
               CM.Include (Union_Id (N), Initializes_CM);
            end if;
         end;
      end if;

   end Do_Package_Body_Or_Stub;

   ---------------
   -- Do_Pragma --
   ---------------

   procedure Do_Pragma
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
   is

      function Find_Execution_Kind return Execution_Kind_T;
      --  Figures out the pragma's execution kind. For
      --  statically-false assertions we set the Execution to
      --  Abnormal_Termination.

      procedure fip;
      --  A dummy procedure called when pragma Inspection_Point is
      --  processed. This is just to help debugging Why generation. If a
      --  pragma Inspection_Point is added to a source program, then
      --  breaking on fip will get you to that point in the program.

      function Proc (N : Node_Id) return Traverse_Result;
      --  Adds N to the appropriate entry references of the current
      --  context, if N is a loop_entry reference.

      -------------------------
      -- Find_Execution_Kind --
      -------------------------

      function Find_Execution_Kind return Execution_Kind_T is
      begin
         if Get_Pragma_Id (N) /= Pragma_Check then
            return Normal_Execution;
         end if;

         declare
            PAA : constant Node_Id := First (Pragma_Argument_Associations (N));

            function Was_Assertion return Boolean;
            --  Checks if this pragma is a rewritten assert pragma.

            function Is_Statically_False return Boolean;
            --  Checks if the rewritten assertion has a
            --  statically-false argument.

            -------------------
            -- Was_Assertion --
            -------------------

            function Was_Assertion return Boolean is
              (Present (PAA)
                 and then Nkind (Expression (PAA)) = N_Identifier
                 and then Get_Name_String (Chars (Expression (PAA))) =
                            "assert");

            -------------------------
            -- Is_Statically_False --
            -------------------------

            function Is_Statically_False return Boolean is
              (Present (Next (PAA))
                 and then Nkind (Expression (Next (PAA))) =
                            N_Identifier
                 and then Entity (Expression (Next (PAA))) =
                            Standard_False);

         begin
            if Was_Assertion
              and then Is_Statically_False
            then
               return Abnormal_Termination;
            else
               return Normal_Execution;
            end if;
         end;
      end Find_Execution_Kind;

      ---------
      -- fip --
      ---------

      procedure fip is
      begin
         null;
      end fip;

      ----------
      -- Proc --
      ----------

      function Proc (N : Node_Id) return Traverse_Result is
         Loop_Name : Node_Id;
      begin
         case Nkind (N) is
            when N_Attribute_Reference =>
               case Get_Attribute_Id (Attribute_Name (N)) is
                  when Attribute_Loop_Entry =>
                     pragma Assert (Present (Ctx.Active_Loop));

                     if Present (Expressions (N)) then
                        --  This is a named loop entry reference
                        --  (i.e. X'Loop_Entry (Foo))
                        pragma Assert (List_Length (Expressions (N)) = 1);
                        Loop_Name := First (Expressions (N));
                        pragma Assert (Nkind (Loop_Name) = N_Identifier);
                        Ctx.Entry_References (Entity (Loop_Name)).Include (N);

                     else
                        Ctx.Entry_References (Ctx.Active_Loop).Include (N);
                     end if;
                  when others =>
                     null;
               end case;

            when others =>
               null;
         end case;
         return OK;
      end Proc;

      procedure Add_Loop_Entry_References is new Traverse_Proc (Proc);

      V     : Flow_Graphs.Vertex_Id;
      Funcs : Node_Sets.Set;

   --  Start of processing for Do_Pragma

   begin
      if Pragma_Relevant_To_Flow (N) then

         case Get_Pragma_Id (N) is

            when Pragma_Unmodified   |
                 Pragma_Unreferenced =>

               --  For pragma unmodified and pragma unreferenced we
               --  produce a null vertex.
               Add_Vertex (FA, Null_Node_Attributes, V);

               declare
                  Argument_Association : Node_Id;
                  Associated_Variable  : Node_Id;
               begin
                  Argument_Association :=
                    First (Pragma_Argument_Associations (N));

                  while Present (Argument_Association) loop
                     Associated_Variable :=
                       Associated_Node (Expression (Argument_Association));

                     if not Is_Subprogram (Associated_Variable) then
                        if Get_Pragma_Id (N) = Pragma_Unmodified then
                           --  If a pragma Unmodified was found, we insert
                           --  its associated variable to the set of
                           --  unmodified variables.
                           FA.Unmodified_Vars.Insert (Associated_Variable);
                        else
                           --  If a pragma Unreferenced was found, we insert
                           --  its associated variable to the set of
                           --  unreferenced variables.
                           FA.Unreferenced_Vars.Insert (Associated_Variable);
                        end if;
                     end if;

                     Argument_Association := Next (Argument_Association);
                  end loop;
               end;

            when others =>
               --  If we are processing a pragma that is relevant to
               --  flow analysis, and we are not dealing with either
               --  pragma unmodified or pragma unreferenced then we
               --  create a sink vertex to check for uninitialized
               --  variables.
               Collect_Functions_And_Read_Locked_POs
                 (N,
                  Functions_Called   => Funcs,
                  Tasking            => FA.Tasking,
                  Include_Predicates => FA.Generating_Globals);

               Add_Vertex
                 (FA,
                  Direct_Mapping_Id (N),
                  Make_Sink_Vertex_Attributes
                    (FA         => FA,
                     Var_Use    => Get_Variable_Set
                       (Pragma_Argument_Associations (N),
                        Scope                => FA.B_Scope,
                        Local_Constants      => FA.Local_Constants,
                        Fold_Functions       => False,
                        Use_Computed_Globals => not FA.Generating_Globals),
                     Sub_Called => Funcs,
                     Is_Proof   => True,
                     E_Loc      => N,
                     Execution  => Find_Execution_Kind),
                  V);
         end case;

      else
         --  Otherwise we produce a null vertex.
         Add_Vertex (FA, Null_Node_Attributes, V);

         --  Pragma Inspection_Point is also ignored, but we insert a call
         --  to a dummy procedure, to allow to break on it during
         --  debugging.

         if Get_Pragma_Id (N) = Pragma_Inspection_Point then
            fip;
         end if;

      end if;

      CM.Include (Union_Id (N), Trivial_Connection (V));

      --  We make a note of 'Loop_Entry uses.
      case Get_Pragma_Id (N) is
         when Pragma_Check | Pragma_Loop_Variant | Pragma_Loop_Invariant =>
            Add_Loop_Entry_References (N);

         when others =>
            null;
      end case;

   end Do_Pragma;

   ---------------------
   -- Do_Precondition --
   ---------------------

   procedure Do_Precondition
     (Pre : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
   is
      pragma Unreferenced (Ctx);
      V : Flow_Graphs.Vertex_Id;
      Funcs : Node_Sets.Set;
   begin
      --  We just need to check for uninitialized variables.
      Collect_Functions_And_Read_Locked_POs
        (Pre,
         Functions_Called   => Funcs,
         Tasking            => FA.Tasking,
         Include_Predicates => FA.Generating_Globals);

      Add_Vertex
        (FA,
         Direct_Mapping_Id (Pre),
         Make_Sink_Vertex_Attributes
           (FA              => FA,
            Var_Use         => Get_Variable_Set
              (Pre,
               Scope                => FA.B_Scope,
               Local_Constants      => FA.Local_Constants,
               Fold_Functions       => False,
               Use_Computed_Globals => not FA.Generating_Globals),
            Sub_Called      => Funcs,
            Is_Proof        => True,
            Is_Precondition => True,
            E_Loc           => Pre),
         V);

      CM.Include (Union_Id (Pre), Trivial_Connection (V));
   end Do_Precondition;

   -------------------------
   --  Do_Call_Statement  --
   -------------------------

   procedure Do_Call_Statement
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
   is
      Called_Thing   : constant Entity_Id := Get_Called_Entity (N);
      Called_Thing_F : constant Flow_Id   := Direct_Mapping_Id (Called_Thing);

      Ins  : Vertex_Vectors.Vector := Vertex_Vectors.Empty_Vector;
      Outs : Vertex_Vectors.Vector := Vertex_Vectors.Empty_Vector;

      V : Flow_Graphs.Vertex_Id;
      C : Flow_Graphs.Cluster_Id;

      function Suspends_On_Suspension_Object return Boolean;
      --  Check if Called_Thing suspends on a suspension object, i.e. it is
      --  Ada.Synchronous_Task_Control.Suspend_Until_True or
      --  Ada.Synchronous_Task_Control.EDF.Suspend_Until_True_And_Set_Deadline

      function Suspends_On_Suspension_Object return Boolean is
         Scop : Entity_Id := Called_Thing;

         procedure Scope_Up;
         --  Climb up the scope

         --------------
         -- Scope_Up --
         --------------

         procedure Scope_Up is
         begin
            Scop := Scope (Scop);
         end Scope_Up;

         Called_String : constant String := Get_Name_String (Chars (Scop));
         --  Name of the called procedure

      --  Start of processing for Suspends_On_Suspension_Object

      begin
         if Called_String = "suspend_until_true" then
            Scope_Up;
         elsif Called_String = "suspend_until_true_and_set_deadline" then
            Scope_Up;
            if Get_Name_String (Chars (Scop)) = "edf" then
               Scope_Up;
            else
               return False;
            end if;
         else
            return False;
         end if;

         if Chars (Scop) = Name_Synchronous_Task_Control then
            Scope_Up;
         else
            return False;
         end if;

         if Chars (Scop) = Name_Ada then
            Scope_Up;
         else
            return False;
         end if;

         return Scop = Standard_Standard;
      end Suspends_On_Suspension_Object;

   --  Start of processing for Do_Call_Statement

   begin
      --  Add a cluster to help pretty printing.
      FA.CFG.New_Cluster (C);

      --  A vertex for the actual call.
      Add_Vertex
        (FA,
         Direct_Mapping_Id (N),
         Make_Call_Attributes
           (FA         => FA,
            Callsite   => N,
            Sub_Called => Node_Sets.To_Set (Called_Thing),
            Loops      => Ctx.Current_Loops,
            E_Loc      => N),
         V);
      FA.CFG.Set_Cluster (V, C);

      --  Deal with the subprogram's parameters.
      Process_Parameter_Associations (N,
                                      Ins,
                                      Outs,
                                      FA, CM, Ctx);

      --  We process globals when:
      --     * the globals have already been generated or
      --     * when the user has supplied them and we don't have to rely
      --       on the generated ones
      if not FA.Generating_Globals
        or else (Has_User_Supplied_Globals (Called_Thing)
                   and then not Rely_On_Generated_Global (Called_Thing,
                                                          FA.B_Scope))
      then
         Process_Subprogram_Globals (N,
                                     Ins, Outs,
                                     FA, CM, Ctx);
      end if;

      --  For subprogram and entry calls that are declared directly inside a
      --  protected object we need an extra magic parameter that models the
      --  protected object itself.
      if Belongs_To_Protected_Object (Called_Thing_F) then
         declare
            --  For external calls we get the protected *object*;
            --  for internal calls we get the protected *type.
            The_PO_Ent : constant Entity_Id :=
              (if Nkind (Name (N)) = N_Selected_Component
               then Get_Enclosing_Object (Name (N))
               else Scope (Called_Thing));

            The_PO : constant Flow_Id := Direct_Mapping_Id (The_PO_Ent);

            V      : Flow_Graphs.Vertex_Id;
         begin
            --  Reading
            Add_Vertex
              (FA,
               Make_Global_Attributes
                 (FA                           => FA,
                  Call_Vertex                  => N,
                  Global                       => Change_Variant (The_PO,
                                                                  In_View),
                  Discriminants_Or_Bounds_Only => False,
                  Loops                        => Ctx.Current_Loops,
                  E_Loc                        => N),
               V);
            Ins.Append (V);

            --  Writing
            Add_Vertex
              (FA,
               Make_Global_Attributes
                 (FA                           => FA,
                  Call_Vertex                  => N,
                  Global                       => Change_Variant (The_PO,
                                                                  Out_View),
                  Discriminants_Or_Bounds_Only => False,
                  Loops                        => Ctx.Current_Loops,
                  E_Loc                        => N),
               V);
            Outs.Append (V);

            --  Collect tasking-related information
            case Convention (Called_Thing) is
               when Convention_Entry =>
                  FA.Tasking (Entry_Calls).Include (The_PO_Ent);
                  FA.Tasking (Write_Locks).Include (The_PO_Ent);

               when Convention_Protected =>
                  FA.Tasking (Write_Locks).Include (The_PO_Ent);

               when others =>
                  null;
            end case;
         end;
      end if;

      --  Check for suspending on a suspension object
      if Suspends_On_Suspension_Object then
         FA.Tasking (Suspends_On).Include
           (Get_Enclosing_Object (First_Actual (N)));
      end if;

      --  A magic null export is needed when:
      --    * there is a usable Depends => (null => ...);
      --    * the subprogram has no exports
      --
      --  Notice that we can only use the Depends when it:
      --    * does not need to be refined or
      --    * it has already been refined
      if Has_Depends (Called_Thing)
        and then (not FA.Generating_Globals
                    or else not Rely_On_Generated_Global (Called_Thing,
                                                          FA.B_Scope))
      then
         --  Check if there exists a usable Depends => (null => ...)
         declare
            D_Map : Dependency_Maps.Map;
            V     : Flow_Graphs.Vertex_Id;
         begin
            Get_Depends (Subprogram           => Called_Thing,
                         Scope                => FA.B_Scope,
                         Classwide            => Is_Dispatching_Call (N),
                         Depends              => D_Map,
                         Use_Computed_Globals => not FA.Generating_Globals);
            if D_Map.Contains (Null_Flow_Id)
              and then D_Map (Null_Flow_Id).Length >= 1
            then
               Add_Vertex
                 (FA,
                  Make_Global_Attributes
                    (FA                           => FA,
                     Call_Vertex                  => N,
                     Global                       => Change_Variant
                       (Null_Export_Flow_Id, Out_View),
                     Discriminants_Or_Bounds_Only => False,
                     Loops                        => Ctx.Current_Loops,
                     E_Loc                        => N),
                  V);
               Outs.Append (V);
            end if;
         end;
      elsif Outs.Is_Empty then
         --  Check if there are no exports
         declare
            V : Flow_Graphs.Vertex_Id;
         begin
            Add_Vertex
              (FA,
               Make_Global_Attributes
                 (FA                           => FA,
                  Call_Vertex                  => N,
                  Global                       => Change_Variant
                    (Null_Export_Flow_Id, Out_View),
                  Discriminants_Or_Bounds_Only => False,
                  Loops                        => Ctx.Current_Loops,
                  E_Loc                        => N),
               V);
            Outs.Append (V);
         end;
      end if;

      --  We now build the connection map for this sequence.
      declare
         use Vertex_Vectors;
         Combined_List : constant Vertex_Vectors.Vector :=
           Vertex_Vectors.To_Vector (V, 1) & Ins & Outs;
         Prev          : Flow_Graphs.Vertex_Id;
      begin
         Prev := Flow_Graphs.Null_Vertex;
         for V of Combined_List loop
            if Prev /= Flow_Graphs.Null_Vertex then
               FA.CFG.Add_Edge (Prev, V, EC_Default);
            end if;
            FA.CFG.Set_Cluster (V, C);

            Prev := V;
         end loop;

         if No_Return (Called_Thing) then
            CM.Include
              (Union_Id (N),
               Graph_Connections'
                 (Standard_Entry => V,
                  Standard_Exits => Vertex_Sets.Empty_Set));
            FA.Atr (V).Execution :=
              Get_Execution_Kind (Called_Thing,
                                  After_GG => not FA.Generating_Globals);
            Linkup (FA, Prev, FA.Helper_End_Vertex);
         else
            CM.Include
              (Union_Id (N),
               Graph_Connections'
                 (Standard_Entry => V,
                  Standard_Exits => Vertex_Sets.To_Set (Prev)));
         end if;
      end;
   end Do_Call_Statement;

   ----------------------
   -- Do_Postcondition --
   ----------------------

   procedure Do_Postcondition
     (Post : Node_Id;
      FA   : in out Flow_Analysis_Graphs;
      CM   : in out Connection_Maps.Map;
      Ctx  : in out Context)
   is
      pragma Unreferenced (Ctx);
      V : Flow_Graphs.Vertex_Id;
      Funcs : Node_Sets.Set;
   begin
      --  We only need to check for uninitialized variables.
      Collect_Functions_And_Read_Locked_POs
        (Post,
         Functions_Called   => Funcs,
         Tasking            => FA.Tasking,
         Include_Predicates => FA.Generating_Globals);

      Add_Vertex
        (FA,
         Direct_Mapping_Id (Post),
         Make_Sink_Vertex_Attributes
           (FA               => FA,
            Var_Use          => Get_Variable_Set
              (Post,
               Scope                => FA.B_Scope,
               Local_Constants      => FA.Local_Constants,
               Fold_Functions       => False,
               Use_Computed_Globals => not FA.Generating_Globals),
            Sub_Called       => Funcs,
            Is_Proof         => True,
            Is_Postcondition => True,
            E_Loc            => Post),
         V);

      CM.Include (Union_Id (Post), Trivial_Connection (V));
   end Do_Postcondition;

   ----------------------------------
   --  Do_Simple_Return_Statement  --
   ----------------------------------

   procedure Do_Simple_Return_Statement
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
   is
      V : Flow_Graphs.Vertex_Id;
      Funcs : Node_Sets.Set;
   begin
      if No (Expression (N)) then
         --  We have a return for a procedure.
         Add_Vertex (FA,
                     Direct_Mapping_Id (N),
                     Make_Aux_Vertex_Attributes (E_Loc => N),
                     V);
      else
         --  We have a function return.
         Collect_Functions_And_Read_Locked_POs
           (Expression (N),
            Functions_Called   => Funcs,
            Tasking            => FA.Tasking,
            Include_Predicates => FA.Generating_Globals);

         Add_Vertex
           (FA,
            Direct_Mapping_Id (N),
            Make_Basic_Attributes
              (FA         => FA,
               Var_Def    => Flatten_Variable (FA.Analyzed_Entity,
                                               FA.B_Scope),
               Var_Ex_Use => Get_Variable_Set
                 (Expression (N),
                  Scope                => FA.B_Scope,
                  Local_Constants      => FA.Local_Constants,
                  Fold_Functions       => True,
                  Use_Computed_Globals => not FA.Generating_Globals),
               Sub_Called => Funcs,
               Loops      => Ctx.Current_Loops,
               E_Loc      => N),
            V);
         Ctx.Folded_Function_Checks (N).Insert (Expression (N));
      end if;

      --  Control flows in, but we do not flow out again.
      CM.Include (Union_Id (N),
                  Graph_Connections'(Standard_Entry => V,
                                     Standard_Exits => Empty_Set));

      --  Instead we link this vertex directly to the helper end vertex.
      Linkup (FA, V, FA.Helper_End_Vertex);
   end Do_Simple_Return_Statement;

   ----------------------------
   -- Do_Subprogram_Or_Block --
   ----------------------------

   procedure Do_Subprogram_Or_Block
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
   is
      L     : Union_Lists.List := Union_Lists.Empty_List;
      Block : Graph_Connections;
   begin
      if Present (Declarations (N)) then
         Process_Statement_List (Declarations (N), FA, CM, Ctx);
         L.Append (Union_Id (Declarations (N)));
      end if;

      if Present (Handled_Statement_Sequence (N)) then
         Process_Statement (Handled_Statement_Sequence (N), FA, CM, Ctx);
         L.Append (Union_Id (Handled_Statement_Sequence (N)));
      end if;

      Join (FA, CM, L, Block);

      if Nkind (N) = N_Entry_Body then
         declare
            Cond : constant Node_Id := Condition (Entry_Body_Formal_Part (N));
            V_C  : Flow_Graphs.Vertex_Id;
            V    : Flow_Graphs.Vertex_Id;
            Funcs : Node_Sets.Set;
         begin
            Collect_Functions_And_Read_Locked_POs
              (Cond,
               Functions_Called   => Funcs,
               Tasking            => FA.Tasking,
               Include_Predicates => FA.Generating_Globals);

            Add_Vertex
              (FA,
               Direct_Mapping_Id (Cond),
               Make_Basic_Attributes
                 (FA         => FA,
                  Var_Ex_Use => Get_Variable_Set
                    (Cond,
                     Scope                => FA.B_Scope,
                     Local_Constants      => FA.Local_Constants,
                     Fold_Functions       => False,
                     Use_Computed_Globals => not FA.Generating_Globals),
                  Sub_Called => Funcs,
                  Loops      => Ctx.Current_Loops,
                  E_Loc      => Cond,
                  Print_Hint => Pretty_Print_Entry_Barrier),
               V_C);
            --  Ctx.Folded_Function_Checks (N).Insert (Cond);
            --  ??? O429-046 stitch actions?

            Add_Vertex
              (FA,
               Direct_Mapping_Id (Entry_Body_Formal_Part (N)),
               Make_Aux_Vertex_Attributes
                 (E_Loc     => Entry_Body_Formal_Part (N),
                  Execution => Barrier),
               V);

            Linkup (FA, V_C, Block.Standard_Entry);
            Linkup (FA, V_C, V);

            Block.Standard_Entry := V_C;
            Block.Standard_Exits.Include (V);
         end;
      end if;

      CM.Include (Union_Id (N), Block);
   end Do_Subprogram_Or_Block;

   -------------------------
   -- Do_Type_Declaration --
   -------------------------

   procedure Do_Type_Declaration
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
   is
      V   : Flow_Graphs.Vertex_Id;
      Typ : constant Node_Id := Defining_Identifier (N);
   begin
      Add_Vertex
        (FA,
         Direct_Mapping_Id (N),
         Null_Attributes,
         V);
      CM.Include (Union_Id (N), Trivial_Connection (V));

      --  If the type has a Default_Initial_Condition then we:
      --    * add vertices for variables introduced by quantified
      --      Expressions
      --    * check if the full type is as the aspect suggested
      --      and issue a warning if not
      if Has_Default_Init_Cond (Typ)
        or else Has_Inherited_Default_Init_Cond (Typ)
      then
         if Present (Default_Init_Cond_Procedure (Typ)) then
            declare
               Expr : constant Node_Id := Get_Expr_From_Check_Only_Proc
                 (Default_Init_Cond_Procedure (Typ));
            begin
               --  Process quantified expressions
               if Present (Expr) then
                  Process_Quantified_Expressions (Expr, FA, CM, Ctx);
               end if;
            end;
         end if;

         --  Issue a warning if the declared type promised to be
         --  default initialized but is not.
         --
         --  We do not issue this warning:
         --    * during the global generation phase,
         --    * when dealing with an internal type (this is fine
         --      since we will get a warning on the type that comes from
         --      source anyway).

         if not FA.Generating_Globals
           and then Comes_From_Source (Typ)
           and then (not Is_Private_Type (Typ)
                       or else No (Full_View (Typ)))
           and then not Full_View_Not_In_SPARK (Typ)
           and then Is_Default_Initialized (Direct_Mapping_Id (Typ))
           and then not Is_Default_Initialized (Direct_Mapping_Id (Typ),
                                                Explicit_Only => True)
         then
            Error_Msg_Flow
              (FA   => FA,
               Msg  => "type & is not fully initialized",
               N    => N,
               F1   => Direct_Mapping_Id (Typ),
               Tag  => Default_Initialization_Missmatch,
               Kind => Medium_Check_Kind);
         end if;
      end if;
   end Do_Type_Declaration;

   ------------------------------------
   -- Process_Quantified_Expressions --
   ------------------------------------

   procedure Process_Quantified_Expressions
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
   is
      pragma Unreferenced (CM, Ctx);

      function Proc (N : Node_Id) return Traverse_Result;
      --  Traverses the tree looking for quantified expressions. Once
      --  it finds one, it creates the 'initial and 'final vertices
      --  for the variable introduced by the quantified expression.

      ----------
      -- Proc --
      ----------

      function Proc (N : Node_Id) return Traverse_Result is
      begin
         case Nkind (N) is
            when N_Package_Body               |
                 N_Package_Declaration        |
                 N_Subprogram_Body            |
                 N_Subprogram_Declaration     |
                 N_Protected_Body             |
                 N_Protected_Type_Declaration |
                 N_Entry_Body                 |
                 N_Entry_Declaration          |
                 N_Task_Body                  |
                 N_Task_Definition            =>
               --  If we ever get one of these we skip the rest of the
               --  nodes that hang under them.
               return Skip;

            when N_Pragma =>
               if Pragma_Relevant_To_Flow (N) then
                  return OK;
               else
                  return Skip;
               end if;

            when N_Quantified_Expression =>
               if Present (Iterator_Specification (N)) then
                  Create_Initial_And_Final_Vertices
                    (Defining_Identifier (Iterator_Specification (N)),
                     Quantified_Variable_Kind,
                     FA);
               elsif Present (Loop_Parameter_Specification (N)) then
                  Create_Initial_And_Final_Vertices
                    (Defining_Identifier (Loop_Parameter_Specification (N)),
                     Quantified_Variable_Kind,
                     FA);
               else
                  Print_Tree_Node (N);
                  raise Why.Unexpected_Node;
               end if;

            when others =>
               null;
         end case;

         return OK;
      end Proc;

      procedure Traverse is new Traverse_Proc (Process => Proc);
   begin
      Traverse (N);
   end Process_Quantified_Expressions;

   procedure Process_Quantified_Expressions
     (L   : List_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
   is
      N : Node_Id := First (L);
   begin
      while Present (N) loop
         Process_Quantified_Expressions (N, FA, CM, Ctx);
         Next (N);
      end loop;
   end Process_Quantified_Expressions;

   --------------------------------
   -- Process_Subprogram_Globals --
   --------------------------------

   procedure Process_Subprogram_Globals
     (Callsite : Node_Id;
      Ins      : in out Vertex_Vectors.Vector;
      Outs     : in out Vertex_Vectors.Vector;
      FA       : in out Flow_Analysis_Graphs;
      CM       : in out Connection_Maps.Map;
      Ctx      : in out Context)
   is
      pragma Unreferenced (CM);

      Proof_Reads : Flow_Id_Sets.Set;
      Reads       : Flow_Id_Sets.Set;
      Writes      : Flow_Id_Sets.Set;
      V           : Flow_Graphs.Vertex_Id;
   begin
      --  Obtain globals (either from contracts or the computed
      --  stuff).
      Get_Globals (Subprogram           => Get_Called_Entity (Callsite),
                   Scope                => FA.B_Scope,
                   Classwide            => Is_Dispatching_Call (Callsite),
                   Proof_Ins            => Proof_Reads,
                   Reads                => Reads,
                   Writes               => Writes,
                   Use_Computed_Globals => not FA.Generating_Globals);
      Reads.Union (Proof_Reads);

      for R of Reads loop
         Add_Vertex (FA,
                     Make_Global_Attributes
                       (FA                           => FA,
                        Call_Vertex                  => Callsite,
                        Global                       => R,
                        Discriminants_Or_Bounds_Only => False,
                        Loops                        => Ctx.Current_Loops,
                        E_Loc                        => Callsite),
                     V);
         Ins.Append (V);
      end loop;

      for W of Writes loop
         if not Reads.Contains (Change_Variant (W, In_View)) then
            Add_Vertex
              (FA,
               Make_Global_Attributes
                 (FA                           => FA,
                  Call_Vertex                  => Callsite,
                  Global                       => Change_Variant (W, In_View),
                  Discriminants_Or_Bounds_Only => True,
                  Loops                        => Ctx.Current_Loops,
                  E_Loc                        => Callsite),
               V);
            Ins.Append (V);
         end if;
         Add_Vertex (FA,
                     Make_Global_Attributes
                       (FA                           => FA,
                        Call_Vertex                  => Callsite,
                        Global                       => W,
                        Discriminants_Or_Bounds_Only => False,
                        Loops                        => Ctx.Current_Loops,
                        E_Loc                        => Callsite),
                     V);
         Outs.Append (V);
      end loop;

   end Process_Subprogram_Globals;

   --------------------------------------
   --  Process_Parameter_Associations  --
   --------------------------------------

   procedure Process_Parameter_Associations
     (Callsite : Node_Id;
      Ins      : in out Vertex_Vectors.Vector;
      Outs     : in out Vertex_Vectors.Vector;
      FA       : in out Flow_Analysis_Graphs;
      CM       : in out Connection_Maps.Map;
      Ctx      : in out Context)
   is
      pragma Unreferenced (CM);

      Called_Subprogram : constant Entity_Id := Get_Called_Entity (Callsite);

      P                 : Node_Id;

      V                 : Flow_Graphs.Vertex_Id;

      Actual            : Node_Id;
      Formal            : Node_Id;
      Call              : Node_Id;
      Funcs             : Node_Sets.Set;
   begin
      --  Create initial nodes for the statements.
      P := First (Parameter_Associations (Callsite));
      while Present (P) loop
         case Nkind (P) is
            when N_Parameter_Association =>
               --  F (A => B)
               Actual := Explicit_Actual_Parameter (P);
            when others =>
               --  F (B)
               Actual := P;
         end case;

         Find_Actual (Actual, Formal, Call);
         pragma Assert (Get_Called_Entity (Call) = Called_Subprogram);
         pragma Assert (Is_Formal (Formal));

         --  Build an in vertex.
         Collect_Functions_And_Read_Locked_POs
           (Actual,
            Functions_Called   => Funcs,
            Tasking            => FA.Tasking,
            Include_Predicates => FA.Generating_Globals);

         Add_Vertex
           (FA,
            Direct_Mapping_Id (P, In_View),
            Make_Parameter_Attributes
              (FA                           => FA,
               Call_Vertex                  => Callsite,
               Actual                       => Actual,
               Formal                       => Formal,
               In_Vertex                    => True,
               Discriminants_Or_Bounds_Only =>
                 Ekind (Formal) = E_Out_Parameter,
               Sub_Called                   => Funcs,
               Loops                        => Ctx.Current_Loops,
               E_Loc                        => P),
            V);
         Ctx.Folded_Function_Checks (Callsite).Insert (Actual);
         Ins.Append (V);

         --  Build an out vertex.
         if Ekind (Formal) in E_In_Out_Parameter | E_Out_Parameter then
            Add_Vertex
              (FA,
               Direct_Mapping_Id (P, Out_View),
               Make_Parameter_Attributes
                 (FA                           => FA,
                  Call_Vertex                  => Callsite,
                  Actual                       => Actual,
                  Formal                       => Formal,
                  In_Vertex                    => False,
                  Discriminants_Or_Bounds_Only => False,
                  Loops                        => Ctx.Current_Loops,
                  E_Loc                        => P),
               V);
            Outs.Append (V);
         end if;
         --  Go to the next statement
         P := Next (P);
      end loop;
   end Process_Parameter_Associations;

   ------------------------------
   --  Process_Statement_List  --
   ------------------------------

   procedure Process_Statement_List
     (L   : List_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
   is
      P              : Node_Or_Entity_Id;
      Statement_List : Union_Lists.List := Union_Lists.Empty_List;
      Block          : Graph_Connections;
   begin
      --  Create initial nodes for the statements.
      P := First (L);
      while Present (P) loop
         case Nkind (P) is
            when Nodes_Ignored_By_Process_Statement =>
               --  We completely skip these.
               null;

            when others =>
               Process_Statement (P, FA, CM, Ctx);
               Statement_List.Append (Union_Id (P));

         end case;
         P := Next (P);
      end loop;

      --  Produce the joined up list.
      Join (FA    => FA,
            CM    => CM,
            Nodes => Statement_List,
            Block => Block);
      CM.Include (Union_Id (L), Block);

   end Process_Statement_List;

   -------------------------
   --  Process_Statement  --
   -------------------------

   procedure Process_Statement
     (N   : Node_Id;
      FA  : in out Flow_Analysis_Graphs;
      CM  : in out Connection_Maps.Map;
      Ctx : in out Context)
   is
      L : Vertex_Vectors.Vector := Vertex_Vectors.Empty_Vector;
   begin

      --  Initialize the set of expressions we need to double check.
      Ctx.Folded_Function_Checks.Insert (N, Node_Sets.Empty_Set);

      --  Deal with the statement.
      case Nkind (N) is
         when N_Assignment_Statement =>
            Do_Assignment_Statement (N, FA, CM, Ctx);
         when N_Block_Statement =>
            Do_Subprogram_Or_Block (N, FA, CM, Ctx);
         when N_Case_Statement =>
            Do_Case_Statement (N, FA, CM, Ctx);
         when N_Exit_Statement =>
            Do_Exit_Statement (N, FA, CM, Ctx);
         when N_Extended_Return_Statement =>
            Do_Extended_Return_Statement (N, FA, CM, Ctx);
         when N_Handled_Sequence_Of_Statements =>
            Do_Handled_Sequence_Of_Statements (N, FA, CM, Ctx);
         when N_If_Statement =>
            Do_If_Statement (N, FA, CM, Ctx);
         when N_Loop_Statement =>
            Do_Loop_Statement (N, FA, CM, Ctx);
         when N_Null_Statement =>
            Do_Null_Or_Raise_Statement (N, FA, CM, Ctx);
         when N_Object_Declaration =>
            Do_Object_Declaration (N, FA, CM, Ctx);
         when N_Package_Declaration =>
            Do_Package_Declaration (N, FA, CM, Ctx);
         when N_Package_Body | N_Package_Body_Stub =>
            Do_Package_Body_Or_Stub (N, FA, CM, Ctx);
         when N_Pragma =>
            Do_Pragma (N, FA, CM, Ctx);
         when N_Procedure_Call_Statement | N_Entry_Call_Statement =>
            Do_Call_Statement (N, FA, CM, Ctx);
         when N_Simple_Return_Statement =>
            Do_Simple_Return_Statement (N, FA, CM, Ctx);
         when N_Full_Type_Declaration         |
              N_Subtype_Declaration           |
              N_Private_Extension_Declaration =>
            Do_Type_Declaration (N, FA, CM, Ctx);
         when N_Raise_Statement |
              N_Raise_xxx_Error =>
            Do_Null_Or_Raise_Statement (N, FA, CM, Ctx);
         when N_Exception_Declaration          |
              N_Exception_Renaming_Declaration =>
            Do_Null_Or_Raise_Statement (N, FA, CM, Ctx);
         when N_Delay_Until_Statement | N_Delay_Relative_Statement =>
            Do_Delay_Statement (N, FA, CM, Ctx);
         when N_Component_Declaration =>
            Do_Object_Declaration (N, FA, CM, Ctx);
         when others =>
            Print_Node_Subtree (N);
            --  ??? To be added by various future tickets. Eventually
            --  we will replace this with a Why.Unexpected_Node
            --  exception.
            raise Why.Not_Implemented;
      end case;

      --  We chain the folded function checks in front of the actual vertex
      --  for this statement, if necessary. First we create a vertex for
      --  each expression we need to check.

      for Expr of Ctx.Folded_Function_Checks (N) loop
         declare
            Unchecked : constant Flow_Id_Sets.Set :=
              Get_Variable_Set
              (Expr,
               Scope                => FA.B_Scope,
               Local_Constants      => FA.Local_Constants,
               Fold_Functions       => False,
               Use_Computed_Globals => not FA.Generating_Globals) -

              Get_Variable_Set
              (Expr,
               Scope                => FA.B_Scope,
               Local_Constants      => FA.Local_Constants,
               Fold_Functions       => True,
               Use_Computed_Globals => not FA.Generating_Globals);
            V : Flow_Graphs.Vertex_Id;
         begin
            if Unchecked.Length > 0 then
               Add_Vertex
                 (FA,
                  Make_Sink_Vertex_Attributes (FA            => FA,
                                               Var_Use       => Unchecked,
                                               Is_Fold_Check => True,
                                               E_Loc         => Expr),
                  V);
               L.Append (V);
            end if;
         end;
      end loop;

      --  Then, if we created any new vertices we need to link them in
      --  front of the vertex created for N. We then re-adjust the standard
      --  entry for N.

      if L.Length >= 1 then
         L.Append (CM (Union_Id (N)).Standard_Entry);

         declare
            Prev : Flow_Graphs.Vertex_Id := Flow_Graphs.Null_Vertex;
         begin
            for V of L loop
               if Prev /= Flow_Graphs.Null_Vertex then
                  Linkup (FA, Prev, V);
               end if;
               Prev := V;
            end loop;
         end;

         CM (Union_Id (N)).Standard_Entry := L.First_Element;
      end if;

      --  Finally, we remove the set, so we can do a final sanity check to
      --  make sure all of these have been processed. This sanity check is
      --  in the postcondition of Process_Statement and again at the end of
      --  Create.

      Ctx.Folded_Function_Checks.Delete (N);
   end Process_Statement;

   ----------------------
   -- RHS_Split_Useful --
   ----------------------

   function RHS_Split_Useful (N     : Node_Id;
                              Scope : Flow_Scope)
                              return Boolean is

      function Rec (N : Node_Id) return Boolean;
      --  Recursive helper function.

      function Rec (N : Node_Id) return Boolean is
         T : constant Entity_Id := Get_Type (N, Scope);
      begin
         if not Is_Record_Type (T)
           or else Is_Tagged_Type (T)
           or else Is_Class_Wide_Type (T)
         then
            --  No point in trying to split if we are not dealing with some
            --  record type.
            --  !!! Workaround for N715-015 difficulties - disable this for
            --  !!! any tagged type.
            return False;
         end if;

         case Nkind (N) is
            when N_Identifier | N_Expanded_Name | N_Aggregate =>
               return True;

            when N_Selected_Component =>
               return Rec (Prefix (N));

            when N_Attribute_Reference =>
               return Get_Attribute_Id (Attribute_Name (N)) = Attribute_Update
                 and then Rec (Prefix (N));

            when N_Qualified_Expression | N_Type_Conversion =>
               return Rec (Expression (N));

            when others =>
               return False;
         end case;
      end Rec;

      T : constant Entity_Id :=
        Get_Type ((if Nkind (N) = N_Assignment_Statement then
                      Name (N)
                   else
                      Defining_Identifier (N)),
                  Scope);
   begin
      return not Is_Class_Wide_Type (T)
        and then not Is_Tagged_Type (T)
        and then Rec (Expression (N));
   end RHS_Split_Useful;

   ----------------------------
   -- Mark_Exceptional_Paths --
   ----------------------------

   procedure Mark_Exceptional_Paths (FA : in out Flow_Analysis_Graphs) is
      --  Identification of exceptional paths is a bit tedious. We use a
      --  number of simple DFS passes over the graph which will eventually
      --  flag all vertices belonging to exceptional paths.
      --
      --  1. We need to detect dead code (which is again later detected by
      --     flow-analysis). Detection of exceptional paths will also flag
      --     dead code; since we don't want this we need to know what dead
      --     code is so we can avoid flagging it.
      --
      --  2. We then note which vertices can be reached in a reversed DFS
      --     search (but not crossing ABEND edges) - all remaining vertices
      --     are necessarily exceptional.
      --
      --  3. We need to account for dead code in exceptional paths; we
      --     perform another dead code detection but this time we don't
      --     cross exceptional path vertices in the DFS. We flag all
      --     vertices identified here that have not been identified in the
      --     first step.
      --
      --  4. Finally, when we prune exceptional paths we might leave an if
      --     statement with only a single exit: such a vertex consumes
      --     variables but has no effect on the program. We set
      --     Is_Exceptional_Branch on these vertices so we can ignore them
      --     in flow-analysis.

      Pathable : Vertex_Sets.Set := Vertex_Sets.Empty_Set;  -- Step 1
      Live     : Vertex_Sets.Set := Vertex_Sets.Empty_Set;  -- Step 2
      Dead     : Vertex_Sets.Set;                           -- Step 3

      function Ignore_Abend_Edges (A, B : Flow_Graphs.Vertex_Id)
                                   return Boolean;
      --  Traverses all edges except ABEND edges.

      procedure Mark_Pathable
        (V  : Flow_Graphs.Vertex_Id;
         TV : out Flow_Graphs.Simple_Traversal_Instruction);
      --  Used in step 1 to populate `Pathable'.

      procedure Mark_Live
        (V  : Flow_Graphs.Vertex_Id;
         TV : out Flow_Graphs.Simple_Traversal_Instruction);
      --  Used in step 2 to populate `Live'.

      procedure Mark_Dead
        (V  : Flow_Graphs.Vertex_Id;
         TV : out Flow_Graphs.Simple_Traversal_Instruction);
      --  Used in step 2 to set Is_Exceptional_Path.

      procedure Mark_Reachable
        (V  : Flow_Graphs.Vertex_Id;
         TV : out Flow_Graphs.Simple_Traversal_Instruction);
      --  Used in step 3 to reduce `Dead'.

      ------------------------
      -- Ignore_Abend_Edges --
      ------------------------

      function Ignore_Abend_Edges (A, B : Flow_Graphs.Vertex_Id) return Boolean
      is
      begin
         case FA.CFG.Edge_Colour (A, B) is
            when EC_Default | EC_Barrier | EC_Inf => return True;
            when EC_Abend                         => return False;
            when others                           => raise Program_Error;
         end case;
      end Ignore_Abend_Edges;

      -------------------
      -- Mark_Pathable --
      -------------------

      procedure Mark_Pathable
        (V  : Flow_Graphs.Vertex_Id;
         TV : out Flow_Graphs.Simple_Traversal_Instruction)
      is
      begin
         Pathable.Include (V);
         if V = FA.End_Vertex then
            TV := Flow_Graphs.Skip_Children;
         else
            TV := Flow_Graphs.Continue;
         end if;
      end Mark_Pathable;

      ---------------
      -- Mark_Live --
      ---------------

      procedure Mark_Live (V  : Flow_Graphs.Vertex_Id;
                           TV : out Flow_Graphs.Simple_Traversal_Instruction)
      is
      begin
         if V = FA.Start_Vertex then
            TV := Flow_Graphs.Skip_Children;
         else
            Live.Include (V);
            TV := Flow_Graphs.Continue;
         end if;
      end Mark_Live;

      ---------------
      -- Mark_Dead --
      ---------------

      procedure Mark_Dead (V  : Flow_Graphs.Vertex_Id;
                           TV : out Flow_Graphs.Simple_Traversal_Instruction)
      is
      begin
         if V = FA.End_Vertex then
            TV := Flow_Graphs.Skip_Children;
         else
            if not Live.Contains (V) then
               FA.Atr (V).Is_Exceptional_Path := True;
            end if;
            TV := Flow_Graphs.Continue;
         end if;
      end Mark_Dead;

      --------------------
      -- Mark_Reachable --
      --------------------

      procedure Mark_Reachable
        (V  : Flow_Graphs.Vertex_Id;
         TV : out Flow_Graphs.Simple_Traversal_Instruction)
      is
      begin
         Dead.Exclude (V);
         if V = FA.End_Vertex or FA.Atr.Element (V).Is_Exceptional_Path then
            --  !!! .Element used here because of container bug
            TV := Flow_Graphs.Skip_Children;
         else
            TV := Flow_Graphs.Continue;
         end if;
      end Mark_Reachable;

   --  Start of processing for Mark_Exceptional_Paths

   begin
      --  (1) Detect all non-dead-code vertices and place them in set
      --      `Pathable'.
      FA.CFG.DFS (Start         => FA.Start_Vertex,
                  Include_Start => True,
                  Visitor       => Mark_Pathable'Access);

      --  (2) In reverse, find reachable nodes (not crossing ABEND edges)
      --      and place them in set `Live'.
      FA.CFG.DFS (Start         => FA.End_Vertex,
                  Include_Start => False,
                  Visitor       => Mark_Live'Access,
                  Edge_Selector => Ignore_Abend_Edges'Access,
                  Reversed      => True);

      --  (2) From start, flag all vertices reachable but not in set `Live'.
      FA.CFG.DFS (Start         => FA.Start_Vertex,
                  Include_Start => False,
                  Visitor       => Mark_Dead'Access);

      --  (3) From start, remove all vertices reachable from set `Dead'
      --      (not crossing ABEND edges or exceptional paths).
      Dead := Live;
      FA.CFG.DFS (Start         => FA.Start_Vertex,
                  Include_Start => False,
                  Visitor       => Mark_Reachable'Access,
                  Edge_Selector => Ignore_Abend_Edges'Access);

      --  (3) We combine the above results with the ones from step 1.
      for V of Dead loop
         if Pathable.Contains (V) then
            FA.Atr (V).Is_Exceptional_Path := True;
         end if;
      end loop;

      --  (4) Flag all vertices that have an exceptional path as an out
      --      neighbour.
      for V of FA.CFG.Get_Collection (Flow_Graphs.All_Vertices) loop
         if FA.Atr (V).Is_Exceptional_Path then
            for N of FA.CFG.Get_Collection (V, Flow_Graphs.In_Neighbours) loop
               if not FA.Atr (N).Is_Exceptional_Path then
                  FA.Atr (N).Is_Exceptional_Branch := True;
               end if;
            end loop;
         end if;
      end loop;
   end Mark_Exceptional_Paths;

   -----------------------------
   -- Prune_Exceptional_Paths --
   -----------------------------

   procedure Prune_Exceptional_Paths (FA : in out Flow_Analysis_Graphs) is
      Dead : Vertex_Sets.Set := Vertex_Sets.Empty_Set;
   begin
      for V of FA.CFG.Get_Collection (Flow_Graphs.All_Vertices) loop
         if FA.Atr (V).Is_Exceptional_Path then
            Dead.Include (V);
         end if;
      end loop;
      for V of Dead loop
         FA.CFG.Clear_Vertex (V);
         FA.Atr (V) := Null_Attributes'Update (Is_Null_Node => True);
      end loop;

      --  Sometimes a subprogram is entirely exceptional. In this case we
      --  need to make sure we can still reach the final vertex.
      if not FA.CFG.Non_Trivial_Path_Exists (FA.Start_Vertex, FA.End_Vertex)
      then
         if not FA.Generating_Globals
           and then FA.Kind = Kind_Subprogram
           and then not No_Return (FA.Analyzed_Entity)
         then
            --  We warn about this, but only for subprograms not
            --  annotated with No_Return.
            Error_Msg_Flow
              (FA   => FA,
               Msg  => "no paths in subprogram will return normally",
               N    => FA.Analyzed_Entity,
               Kind => High_Check_Kind,
               Tag  => Missing_Return);
         end if;
         FA.CFG.Add_Edge (FA.Start_Vertex, FA.End_Vertex, EC_Default);
      end if;
   end Prune_Exceptional_Paths;

   -------------------------
   -- Separate_Dead_Paths --
   -------------------------

   procedure Separate_Dead_Paths (FA : in out Flow_Analysis_Graphs) is
      Live : Vertex_Sets.Set := Vertex_Sets.Empty_Set;
      Dead : Vertex_Sets.Set := Vertex_Sets.Empty_Set;

      procedure Mark_Live (V  : Flow_Graphs.Vertex_Id;
                           TV : out Flow_Graphs.Simple_Traversal_Instruction);
      --  Populate `Live'.

      procedure Mark_Dead (V  : Flow_Graphs.Vertex_Id;
                           TV : out Flow_Graphs.Simple_Traversal_Instruction);
      --  Populate `Dead' with all vertices not explicitly live.

      ---------------
      -- Mark_Live --
      ---------------

      procedure Mark_Live (V  : Flow_Graphs.Vertex_Id;
                           TV : out Flow_Graphs.Simple_Traversal_Instruction)
      is
      begin
         Live.Include (V);
         if V = FA.End_Vertex then
            TV := Flow_Graphs.Skip_Children;
         else
            TV := Flow_Graphs.Continue;
         end if;
      end Mark_Live;

      ---------------
      -- Mark_Dead --
      ---------------

      procedure Mark_Dead (V  : Flow_Graphs.Vertex_Id;
                           TV : out Flow_Graphs.Simple_Traversal_Instruction)
      is
      begin
         if not Live.Contains (V) then
            Dead.Include (V);
            TV := Flow_Graphs.Skip_Children;
         elsif V = FA.Start_Vertex then
            TV := Flow_Graphs.Skip_Children;
         else
            TV := Flow_Graphs.Continue;
         end if;
      end Mark_Dead;

   begin
      FA.CFG.DFS (Start         => FA.Start_Vertex,
                  Include_Start => True,
                  Visitor       => Mark_Live'Access);

      FA.CFG.DFS (Start         => FA.End_Vertex,
                  Include_Start => True,
                  Visitor       => Mark_Dead'Access,
                  Reversed      => True);

      for Dead_V of Dead loop
         declare
            Live_Neighbours : Vertex_Sets.Set := Vertex_Sets.Empty_Set;
         begin
            for V of FA.CFG.Get_Collection (Dead_V,
                                            Flow_Graphs.Out_Neighbours)
            loop
               if Live.Contains (V) then
                  Live_Neighbours.Include (V);
               end if;
            end loop;
            for Live_V of Live_Neighbours loop
               FA.CFG.Remove_Edge (Dead_V, Live_V);
            end loop;
         end;
      end loop;
   end Separate_Dead_Paths;

   ------------------
   -- Simplify_CFG --
   ------------------

   procedure Simplify_CFG (FA : in out Flow_Analysis_Graphs) is
   begin
      for V of FA.CFG.Get_Collection (Flow_Graphs.All_Vertices) loop
         if FA.Atr (V).Is_Null_Node then
            --  Close the subgraph indicated by V's neighbours.
            for A of FA.CFG.Get_Collection (V, Flow_Graphs.In_Neighbours) loop
               for B of FA.CFG.Get_Collection (V,
                                               Flow_Graphs.Out_Neighbours)
               loop
                  FA.CFG.Add_Edge (A, B, EC_Default);
               end loop;
            end loop;

            --  Remove all edges from the vertex.
            FA.CFG.Clear_Vertex (V);

            --  Clear the node.
            FA.Atr (V) := Null_Attributes'Update (Is_Null_Node => True);
         end if;
      end loop;
   end Simplify_CFG;

   -----------------------------
   -- Pragma_Relevant_To_Flow --
   -----------------------------

   function Pragma_Relevant_To_Flow (N : Node_Id) return Boolean is
   begin
      case Get_Pragma_Id (N) is
         when Pragma_Check =>
            return not Is_Ignored_Pragma_Check (N);

         when Pragma_Loop_Variant =>
            return True;

         when Pragma_Unmodified   |
              Pragma_Unreferenced =>
            return True;

         --  Do not issue a warning on invariant pragmas, as one is already
         --  issued on the corresponding type in SPARK.Definition.

         when Pragma_Invariant
            | Pragma_Type_Invariant
            | Pragma_Type_Invariant_Class =>
            return False;

         --  Do not issue a warning on unknown pragmas, as one is already
         --  issued in SPARK.Definition.

         when Unknown_Pragma =>
            return False;

         --  Remaining pragmas fall into two major groups:
         --
         --  Group 1 - ignored
         --
         --  Pragmas that do not need any marking, either because:
         --  . they are defined by SPARK 2014, or
         --  . they are already taken into account elsewhere (contracts)
         --  . they have no effect on flow analysis

         --  Group 1a - RM Table 16.1, Ada language-defined pragmas marked
         --  "Yes".
         --  Note: pragma Assert is transformed into an
         --  instance of pragma Check by the front-end.
         when Pragma_Assertion_Policy             |
              Pragma_Atomic                       |
              Pragma_Atomic_Components            |
              Pragma_Convention                   |
              Pragma_Elaborate                    |
              Pragma_Elaborate_All                |
              Pragma_Elaborate_Body               |
              Pragma_Export                       |
              Pragma_Import                       |
              Pragma_Independent                  |
              Pragma_Independent_Components       |
              Pragma_Inline                       |
              Pragma_Linker_Options               |
              Pragma_List                         |
              Pragma_No_Return                    |
              Pragma_Normalize_Scalars            |
              Pragma_Optimize                     |
              Pragma_Pack                         |
              Pragma_Page                         |
              Pragma_Partition_Elaboration_Policy |
              Pragma_Preelaborable_Initialization |
              Pragma_Preelaborate                 |
              Pragma_Profile                      |
              Pragma_Pure                         |
              Pragma_Restrictions                 |
              Pragma_Reviewable                   |
              Pragma_Suppress                     |
              Pragma_Unsuppress                   |
              Pragma_Volatile                     |
              Pragma_Volatile_Components          |
              Pragma_Volatile_Full_Access         |

         --  Group 1b - RM Table 16.2, SPARK language-defined pragmas marked
         --  "Yes", whose effect on flow analysis is taken care of somewhere
         --  else.
         --  Note: pragmas Assert_And_Cut, Assume, and
         --  Loop_Invariant are transformed into instances of
         --  pragma Check by the front-end.
              Pragma_Abstract_State               |
              Pragma_Assume_No_Invalid_Values     |
              Pragma_Async_Readers                |
              Pragma_Async_Writers                |
              Pragma_Constant_After_Elaboration   |
              Pragma_Contract_Cases               |
              Pragma_Depends                      |
              Pragma_Default_Initial_Condition    |
              Pragma_Effective_Reads              |
              Pragma_Effective_Writes             |
              Pragma_Ghost                        |  --  ??? TO DO
              Pragma_Global                       |
              Pragma_Initializes                  |
              Pragma_Initial_Condition            |
              Pragma_Overflow_Mode                |
              Pragma_Part_Of                      |
              Pragma_Postcondition                |
              Pragma_Precondition                 |
              Pragma_Refined_Depends              |
              Pragma_Refined_Global               |
              Pragma_Refined_Post                 |
              Pragma_Refined_State                |
              Pragma_SPARK_Mode                   |
              Pragma_Unevaluated_Use_Of_Old       |
              Pragma_Volatile_Function            |

         --  Group 1c - RM Table 16.3, GNAT implementation-defined pragmas
         --  marked "Yes".
         --  Note: pragma Debug is removed by the front-end.
              Pragma_Ada_83                       |
              Pragma_Ada_95                       |
              Pragma_Ada_05                       |
              Pragma_Ada_2005                     |
              Pragma_Ada_12                       |
              Pragma_Ada_2012                     |
              Pragma_Annotate                     |
              Pragma_Check_Policy                 |
              Pragma_Ignore_Pragma                |
              Pragma_Inline_Always                |
              Pragma_Inspection_Point             |
              Pragma_Linker_Section               |
              Pragma_No_Elaboration_Code_All      |
              Pragma_No_Tagged_Streams            |
              Pragma_Pure_Function                |
              Pragma_Restriction_Warnings         |
              Pragma_Style_Checks                 |
              Pragma_Test_Case                    |
              Pragma_Validity_Checks              |
              Pragma_Warnings                     |
              Pragma_Weak_External                =>
            return False;

         --  Group 1d - pragma that are re-written and/or removed
         --  by the front-end in GNATprove, so they should
         --  never be seen here.
         when Pragma_Assert                       |
              Pragma_Assert_And_Cut               |
              Pragma_Assume                       |
              Pragma_Debug                        |
              Pragma_Loop_Invariant               =>
            raise Program_Error;

         --  Group 2 - Remaining pragmas, enumerated here rather than
         --  a "when others" to force re-consideration when
         --  SNames.Pragma_Id is extended.
         --
         --  These all generate a warning.  In future, these pragmas
         --  may move to be fully ignored or to be processed with more
         --  semantic detail as required.

         --  Group 2a - GNAT Defined and obsolete pragmas
         when Pragma_Abort_Defer                 |
           Pragma_Allow_Integer_Address          |
           Pragma_Attribute_Definition           |
           Pragma_C_Pass_By_Copy                 |
           Pragma_Check_Float_Overflow           |
           Pragma_Check_Name                     |
           Pragma_Comment                        |
           Pragma_Common_Object                  |
           Pragma_Compile_Time_Error             |
           Pragma_Compile_Time_Warning           |
           Pragma_Compiler_Unit                  |
           Pragma_Compiler_Unit_Warning          |
           Pragma_Complete_Representation        |
           Pragma_Complex_Representation         |
           Pragma_Component_Alignment            |
           Pragma_Controlled                     |
           Pragma_Convention_Identifier          |
           Pragma_CPP_Class                      |
           Pragma_CPP_Constructor                |
           Pragma_CPP_Virtual                    |
           Pragma_CPP_Vtable                     |
           Pragma_CPU                            |
           Pragma_Debug_Policy                   |
           Pragma_Default_Scalar_Storage_Order   |
           Pragma_Default_Storage_Pool           |
           Pragma_Detect_Blocking                |
           Pragma_Disable_Atomic_Synchronization |
           Pragma_Dispatching_Domain             |
           Pragma_Elaboration_Checks             |
           Pragma_Eliminate                      |
           Pragma_Enable_Atomic_Synchronization  |
           Pragma_Export_Function                |
           Pragma_Export_Object                  |
           Pragma_Export_Procedure               |
           Pragma_Export_Value                   |
           Pragma_Export_Valued_Procedure        |
           Pragma_Extend_System                  |
           Pragma_Extensions_Allowed             |
           Pragma_External                       |
           Pragma_External_Name_Casing           |
           Pragma_Fast_Math                      |
           Pragma_Favor_Top_Level                |
           Pragma_Finalize_Storage_Only          |
           Pragma_Ident                          |
           Pragma_Implementation_Defined         |
           Pragma_Implemented                    |
           Pragma_Implicit_Packing               |
           Pragma_Import_Function                |
           Pragma_Import_Object                  |
           Pragma_Import_Procedure               |
           Pragma_Import_Valued_Procedure        |
           Pragma_Initialize_Scalars             |
           Pragma_Inline_Generic                 |
           Pragma_Interface                      |
           Pragma_Interface_Name                 |
           Pragma_Interrupt_Handler              |
           Pragma_Interrupt_State                |
           Pragma_Keep_Names                     |
           Pragma_License                        |
           Pragma_Link_With                      |
           Pragma_Linker_Alias                   |
           Pragma_Linker_Constructor             |
           Pragma_Linker_Destructor              |
           Pragma_Loop_Optimize                  |
           Pragma_Machine_Attribute              |
           Pragma_Main                           |
           Pragma_Main_Storage                   |
           Pragma_Memory_Size                    |
           Pragma_No_Body                        |
           Pragma_No_Inline                      |
           Pragma_No_Run_Time                    |
           Pragma_No_Strict_Aliasing             |
           Pragma_Obsolescent                    |
           Pragma_Optimize_Alignment             |
           Pragma_Ordered                        |
           Pragma_Overriding_Renamings           |
           Pragma_Passive                        |
           Pragma_Persistent_BSS                 |
           Pragma_Polling                        |
           Pragma_Post                           |
           Pragma_Post_Class                     |
           Pragma_Pre                            |
           Pragma_Predicate                      |
           Pragma_Predicate_Failure              |
           Pragma_Prefix_Exception_Messages      |
           Pragma_Pre_Class                      |
           Pragma_Priority_Specific_Dispatching  |
           Pragma_Profile_Warnings               |
           Pragma_Propagate_Exceptions           |
           Pragma_Provide_Shift_Operators        |
           Pragma_Psect_Object                   |
           Pragma_Rational                       |
           Pragma_Ravenscar                      |
           Pragma_Relative_Deadline              |
           Pragma_Remote_Access_Type             |
           Pragma_Restricted_Run_Time            |
           Pragma_Share_Generic                  |
           Pragma_Shared                         |
           Pragma_Short_Circuit_And_Or           |
           Pragma_Short_Descriptors              |
           Pragma_Simple_Storage_Pool_Type       |
           Pragma_Source_File_Name               |
           Pragma_Source_File_Name_Project       |
           Pragma_Source_Reference               |
           Pragma_Static_Elaboration_Desired     |
           Pragma_Storage_Unit                   |
           Pragma_Stream_Convert                 |
           Pragma_Subtitle                       |
           Pragma_Suppress_All                   |
           Pragma_Suppress_Debug_Info            |
           Pragma_Suppress_Exception_Locations   |
           Pragma_Suppress_Initialization        |
           Pragma_System_Name                    |
           Pragma_Task_Info                      |
           Pragma_Task_Name                      |
           Pragma_Task_Storage                   |
           Pragma_Thread_Local_Storage           |
           Pragma_Time_Slice                     |
           Pragma_Title                          |
           Pragma_Unchecked_Union                |
           Pragma_Unimplemented_Unit             |
           Pragma_Universal_Aliasing             |
           Pragma_Universal_Data                 |
           Pragma_Unreferenced_Objects           |
           Pragma_Unreserve_All_Interrupts       |
           Pragma_Use_VADS_Size                  |
           Pragma_Warning_As_Error               |
           Pragma_Wide_Character_Encoding        |

           --  Group 2b - Ada RM pragmas
           Pragma_Discard_Names                  |
           Pragma_Locking_Policy                 |
           Pragma_Queuing_Policy                 |
           Pragma_Task_Dispatching_Policy        |
           Pragma_All_Calls_Remote               |
           Pragma_Asynchronous                   |
           Pragma_Attach_Handler                 |
           Pragma_Remote_Call_Interface          |
           Pragma_Remote_Types                   |
           Pragma_Shared_Passive                 |
           Pragma_Interrupt_Priority             |
           Pragma_Lock_Free                      |
           Pragma_Priority                       |
           Pragma_Storage_Size                   =>

            Errout.Error_Msg_Name_1 := Pragma_Name (N);
            Errout.Error_Msg_N
              ("?pragma % ignored in flow analysis (not yet supported)", N);
            return False;

         --  ??? ignored for now, see NA03-003

         when Pragma_Extensions_Visible =>
            return False;
      end case;

   end Pragma_Relevant_To_Flow;

   ------------------------------------------------------------
   --  Package functions and procedures
   ------------------------------------------------------------

   ------------
   -- Create --
   ------------

   procedure Create (FA : in out Flow_Analysis_Graphs) is
      Connection_Map  : Connection_Maps.Map := Connection_Maps.Empty_Map;
      The_Context     : Context             := No_Context;
      Subprogram_Spec : Entity_Id;
      Preconditions   : Node_Lists.List;
      Precon_Block    : Graph_Connections;
      Postcon_Block   : Graph_Connections;
      Body_N          : Node_Id;
      Spec_N          : Node_Id;
      Package_Writes  : Flow_Id_Sets.Set := Flow_Id_Sets.Empty_Set;
   begin
      pragma Assert (Is_Valid (FA));

      case FA.Kind is
         when Kind_Subprogram =>
            Body_N          := Subprogram_Body (FA.Analyzed_Entity);
            Preconditions   :=
              Get_Precondition_Expressions (FA.Analyzed_Entity);

            Subprogram_Spec :=
              (if Acts_As_Spec (Body_N)
               then Defining_Unit_Name (Specification (Body_N))
               else Corresponding_Spec (Body_N));

         when Kind_Entry =>
            Body_N          := Entry_Body (FA.Analyzed_Entity);
            Preconditions   :=
              Get_Precondition_Expressions (FA.Analyzed_Entity);

            Subprogram_Spec := FA.Analyzed_Entity;

         when Kind_Task =>
            --  Tasks cannot have pre- or postconditions right now. This is
            --  a matter for the ARG perhaps.
            Body_N          := Task_Body (FA.Analyzed_Entity);
            Subprogram_Spec := Corresponding_Spec (Body_N);

         when Kind_Package =>
            Spec_N := Package_Specification (FA.Analyzed_Entity);
            Body_N := Spec_N;

         when Kind_Package_Body =>
            Body_N := Package_Body (FA.Analyzed_Entity);
            Spec_N := Package_Specification (Corresponding_Spec (Body_N));

      end case;

      --  Create the magic start, helper end and end vertices.
      declare
         Start_Atr : V_Attributes := Null_Attributes;
      begin
         --  We attach the subprogram's location to the start vertex
         --  as it gives us a convenient way to generate error
         --  messages applying to the whole subprogram/package/body.
         Start_Atr.Error_Location := Body_N;
         Add_Vertex (FA, Start_Atr, FA.Start_Vertex);
      end;
      Add_Vertex (FA, Null_Attributes, FA.Helper_End_Vertex);
      Add_Vertex (FA, Null_Attributes, FA.End_Vertex);

      --  Create the magic null export vertices.
      declare
         F : constant Flow_Id := Change_Variant (Null_Export_Flow_Id,
                                                 Initial_Value);
      begin
         Add_Vertex (FA, F, Make_Null_Export_Attributes (F));
      end;
      declare
         F : constant Flow_Id := Change_Variant (Null_Export_Flow_Id,
                                                 Final_Value);
      begin
         Add_Vertex (FA, F, Make_Null_Export_Attributes (F));
      end;

      --  Collect parameters of the analyzed entity and produce
      --  initial and final vertices.
      case FA.Kind is
         when Kind_Subprogram | Kind_Entry =>
            declare
               E : Entity_Id;
               F : constant Flow_Id := Direct_Mapping_Id (FA.Analyzed_Entity);
            begin
               E := First_Formal (Subprogram_Spec);
               while Present (E) loop
                  Create_Initial_And_Final_Vertices (E, Parameter_Kind, FA);
                  E := Next_Formal (E);
               end loop;

               --  If the subprogram is directly enclosed in a protected object
               --  then add the protected object as a formal parameter to the
               --  subprogram.
               if Belongs_To_Protected_Object (F) then
                  Create_Initial_And_Final_Vertices
                    (Get_Enclosing_Concurrent_Object (F),
                     Parameter_Kind,
                     FA);
               end if;
            end;

         when Kind_Task =>
            --  Tasks see their discriminants as formal in parameters
            declare
               Discr : Entity_Id := First_Discriminant (FA.Analyzed_Entity);
            begin
               while Present (Discr) loop
                  Create_Initial_And_Final_Vertices (Discr,
                                                     Parameter_Kind,
                                                     FA);
                  Next_Discriminant (Discr);
               end loop;
            end;

            --  Add variables that are Part_Of the task as formal in out
            --  parameters to the task.
            declare
               T   : constant Entity_Id := Get_Type (FA.Analyzed_Entity,
                                                     FA.B_Scope);

               AO  : Node_Id;
               Ptr : Elmt_Id;
            begin
               if Present (Anonymous_Object (T)) then
                  AO  := Anonymous_Object (T);
                  Ptr := First_Elmt (Part_Of_Constituents (AO));
                  while Present (Ptr) loop
                     Create_Initial_And_Final_Vertices
                       (Node (Ptr),
                        Parameter_Kind,
                        FA);
                     Ptr := Next_Elmt (Ptr);
                  end loop;
               end if;
            end;

         when Kind_Package | Kind_Package_Body =>
            --  We create initial and final vertices for the package's state
            --  abstractions.
            declare
               AS_Pragma : constant Node_Id :=
                 Get_Pragma (FA.Spec_Entity, Pragma_Abstract_State);

               PAA       : Node_Id;
               AS_N      : Node_Id;
               AS_E      : Entity_Id;
            begin
               if Present (AS_Pragma) then
                  PAA  := First (Pragma_Argument_Associations (AS_Pragma));
                  AS_N := First (Expressions (Expression (PAA)));

                  while Present (AS_N) loop
                     AS_E := Entity (if Nkind (AS_N) = N_Extension_Aggregate
                                     then Ancestor_Part (AS_N)
                                     else AS_N);

                     --  ??? Are those arguments correct ???
                     Create_Initial_And_Final_Vertices
                       (AS_E,
                        Variable_Kind,
                        FA);

                     Next (AS_N);
                  end loop;
               end if;
            end;

            if Is_Generic_Instance (FA.Analyzed_Entity) then
               declare
                  Instance    : constant Node_Id :=
                   Get_Package_Instantiation_Node (FA.Spec_Entity);
                  Association : Node_Id;
                  Parameter   : Node_Id;
               begin
                  --  Sanity check that Instance is indeed an
                  --  N_Package_Instantiation.
                  pragma Assert (Nkind (Instance) = N_Package_Instantiation);

                  Association := First (Generic_Associations (Instance));
                  while Present (Association) loop
                     Parameter := Explicit_Generic_Actual_Parameter
                                    (Association);

                     if Nkind (Parameter) = N_Identifier
                       and then Ekind (Entity (Parameter)) in
                             E_Constant | E_Variable
                     then
                        Create_Initial_And_Final_Vertices
                          (Direct_Mapping_Id (Entity (Parameter)),
                           Mode_In,
                           False,
                           FA);
                     end if;

                     Next (Association);
                  end loop;
               end;
            end if;
      end case;

      --  Collect globals for the analyzed entity and create initial
      --  and final vertices.
      case FA.Kind is
         when Kind_Subprogram | Kind_Entry | Kind_Task =>
            if not FA.Generating_Globals then
               declare
                  type G_Prop is record
                     Is_Read     : Boolean;
                     Is_Write    : Boolean;
                     Is_Proof_In : Boolean;
                  end record;

                  package Global_Maps is new Ada.Containers.Hashed_Maps
                    (Key_Type        => Flow_Id,
                     Element_Type    => G_Prop,
                     Hash            => Hash,
                     Equivalent_Keys => "=",
                     "="             => "=");

                  Proof_Ins : Flow_Id_Sets.Set;
                  Reads     : Flow_Id_Sets.Set;
                  Writes    : Flow_Id_Sets.Set;
                  Globals   : Global_Maps.Map := Global_Maps.Empty_Map;
               begin
                  Get_Globals (Subprogram => Subprogram_Spec,
                               Scope      => FA.B_Scope,
                               Classwide  => False,
                               Proof_Ins  => Proof_Ins,
                               Reads      => Reads,
                               Writes     => Writes);
                  for G of Proof_Ins loop
                     Globals.Include (Change_Variant (G, Normal_Use),
                                      G_Prop'(Is_Read     => False,
                                              Is_Write    => False,
                                              Is_Proof_In => True));
                  end loop;
                  for G of Reads loop
                     Globals.Include (Change_Variant (G, Normal_Use),
                                      G_Prop'(Is_Read     => True,
                                              Is_Write    => False,
                                              Is_Proof_In => False));
                  end loop;
                  for G of Writes loop
                     declare
                        P : G_Prop;
                     begin
                        if Globals.Contains (Change_Variant (G, Normal_Use))
                        then
                           P := Globals (Change_Variant (G, Normal_Use));
                           P.Is_Write := True;
                        else
                           P := G_Prop'(Is_Read     => False,
                                        Is_Write    => True,
                                        Is_Proof_In => False);
                        end if;
                        Globals.Include (Change_Variant (G, Normal_Use), P);

                        --  If we are dealing with a function, since we found a
                        --  global output, we raise an error.
                        if Ekind (FA.Analyzed_Entity) = E_Function then
                           Error_Msg_Flow
                             (FA   => FA,
                              Msg  => "function with output global & " &
                                "is not allowed in SPARK",
                              N    => FA.Analyzed_Entity,
                              F1   => G,
                              Kind => Error_Kind,
                              Tag  => Side_Effects);

                           FA.Function_Side_Effects_Present := True;
                        end if;
                     end;
                  end loop;

                  for C in Globals.Iterate loop
                     declare
                        G : constant Flow_Id := Global_Maps.Key (C);
                        P : constant G_Prop  := Global_Maps.Element (C);

                        Mode : Param_Mode;
                     begin
                        if P.Is_Read and P.Is_Write then
                           Mode := Mode_In_Out;
                        elsif P.Is_Read then
                           Mode := Mode_In;
                        elsif P.Is_Write then
                           Mode := Mode_Out;
                        elsif P.Is_Proof_In then
                           Mode := Mode_Proof;
                        else
                           raise Program_Error;
                        end if;

                        Create_Initial_And_Final_Vertices (G, Mode, False, FA);
                     end;
                  end loop;
               end;
            end if;

         when Kind_Package | Kind_Package_Body =>
            --  Packages have no obvious globals, but we can extract a
            --  list of global variables used from the optional rhs of
            --  the initializes clause:
            --
            --     Initializes => (State => (Global_A, ...),
            --
            --  Any other use of non-local variables is not legal (SRM
            --  7.1.5, verification rule 12).
            --
            --  Any such globals are global inputs *only* as packages
            --  are only allowed to initialize their own state.
            declare
               Global_Ins : Flow_Id_Sets.Set := Flow_Id_Sets.Empty_Set;
               --  We need to make sure to only add each global once
               --  (an entity might be used to derive more than one of
               --  our states).

               The_Out : Flow_Id;
               The_In  : Flow_Id_Sets.Set;
               DM      : constant Dependency_Maps.Map :=
                 Parse_Initializes (FA.Initializes_N,
                                    FA.Spec_Entity,
                                    FA.S_Scope);
            begin
               for C in DM.Iterate loop
                  The_Out := Dependency_Maps.Key (C);
                  The_In  := Dependency_Maps.Element (C);

                  for G of The_In loop
                     if not Global_Ins.Contains (G) then
                        Global_Ins.Include (G);
                        Create_Initial_And_Final_Vertices
                          (F             => G,
                           Mode          => Mode_In,
                           Uninitialized => False,
                           FA            => FA);
                     end if;
                  end loop;

                  if Present (The_Out) then
                     Package_Writes.Include (The_Out);
                  end if;
               end loop;
            end;

            --  If a Refined_State aspect exists, we gather all
            --  constituents that are abstract states and create
            --  Initial and Final vertices for them.

            if FA.Kind = Kind_Package_Body then
               declare
                  Refined_State_N : constant Node_Id :=
                    Get_Pragma (FA.Analyzed_Entity,
                                Pragma_Refined_State);

                  Constituents    : Flow_Id_Sets.Set;
                  DM              : Dependency_Maps.Map;
               begin
                  if Present (Refined_State_N) then
                     DM := Parse_Refined_State (Refined_State_N);
                     for C in DM.Iterate loop
                        Constituents := Dependency_Maps.Element (C);

                        for Constituent of Constituents loop
                           if Is_Abstract_State (Constituent) then
                              --  Found a constituent that is an
                              --  abstract state. We now create
                              --  Initial and Final vertices for it.

                              Create_Initial_And_Final_Vertices
                                (F             => Constituent,
                                 Mode          =>
                                   (if Is_Initialized_At_Elaboration
                                         (Constituent,
                                          FA.B_Scope)
                                    then Mode_In_Out
                                    else Mode_In),
                                 Uninitialized =>
                                   not Is_Initialized_At_Elaboration
                                         (Constituent,
                                          FA.B_Scope),
                                 FA            => FA);
                           end if;
                        end loop;
                     end loop;
                  end if;
               end;
            end if;

      end case;

      --  Collect variables introduced by quantified expressions.
      --  We need to look at the following parts:
      --     - precondition
      --     - postcondition
      --     - initial_condition
      --     - declarative part
      --     - body
      case FA.Kind is
         when Kind_Subprogram | Kind_Entry =>
            for Precondition of Preconditions loop
               Process_Quantified_Expressions
                 (Precondition, FA, Connection_Map, The_Context);
            end loop;
            for Refined in Boolean loop
               declare
                  Postconditions : constant Node_Lists.List :=
                    Get_Postcondition_Expressions (FA.Analyzed_Entity,
                                                   Refined);
               begin
                  for Postcondition of Postconditions loop
                     Process_Quantified_Expressions
                       (Postcondition, FA, Connection_Map, The_Context);
                  end loop;
               end;
            end loop;
            Process_Quantified_Expressions
              (Declarations (Body_N), FA, Connection_Map, The_Context);
            Process_Quantified_Expressions
              (Statements (Handled_Statement_Sequence (Body_N)),
               FA, Connection_Map, The_Context);
            --  ?? O429-046 look into entry barriers

         when Kind_Task =>
            Process_Quantified_Expressions
              (Declarations (Body_N), FA, Connection_Map, The_Context);
            Process_Quantified_Expressions
              (Statements (Handled_Statement_Sequence (Body_N)),
               FA, Connection_Map, The_Context);

         when Kind_Package =>
            Process_Quantified_Expressions
              (Visible_Declarations (Spec_N), FA, Connection_Map, The_Context);
            Process_Quantified_Expressions
              (Private_Declarations (Spec_N), FA, Connection_Map, The_Context);
            --  Look into initial conditions
            declare
               Postconditions : constant Node_Lists.List :=
                 Get_Postcondition_Expressions (FA.Analyzed_Entity,
                                                False);
            begin
               for Postcondition of Postconditions loop
                  Process_Quantified_Expressions
                    (Postcondition, FA, Connection_Map, The_Context);
               end loop;
            end;

         when Kind_Package_Body =>
            --  Look into the spec
            Process_Quantified_Expressions
              (Visible_Declarations (Spec_N), FA, Connection_Map, The_Context);
            Process_Quantified_Expressions
              (Private_Declarations (Spec_N), FA, Connection_Map, The_Context);

            --  Look at the body
            Process_Quantified_Expressions
              (Declarations (Body_N), FA, Connection_Map, The_Context);
            if Present (Handled_Statement_Sequence (Body_N)) then
               Process_Quantified_Expressions
                 (Statements (Handled_Statement_Sequence (Body_N)),
                  FA, Connection_Map, The_Context);
            end if;

            --  Look into initial conditions
            declare
               Postconditions : constant Node_Lists.List :=
                 Get_Postcondition_Expressions (Spec_Entity
                                                  (FA.Analyzed_Entity),
                                                False);
            begin
               for Postcondition of Postconditions loop
                  Process_Quantified_Expressions
                    (Postcondition, FA, Connection_Map, The_Context);
               end loop;
            end;

      end case;

      --  If we are dealing with a function, we use its entity to deal
      --  with the value returned.
      if Ekind (FA.Analyzed_Entity) = E_Function then
         Create_Initial_And_Final_Vertices (FA.Analyzed_Entity,
                                            Variable_Kind,
                                            FA);
      end if;

      --  If you're now wondering where we deal with locally declared
      --  objects; we deal with them as they are encountered. See
      --  Do_Object_Declaration for enlightenment.

      --  Produce flowgraph for the precondition and postcondition if
      --  any.
      case FA.Kind is
         when Kind_Subprogram | Kind_Entry  =>
            --  Flowgraph for preconditions and left hand sides of
            --  contract cases.
            declare
               NL : Union_Lists.List := Union_Lists.Empty_List;
            begin
               for Precondition of Preconditions loop
                  Do_Precondition (Precondition,
                                   FA,
                                   Connection_Map,
                                   The_Context);
                  NL.Append (Union_Id (Precondition));
               end loop;
               Join (FA    => FA,
                     CM    => Connection_Map,
                     Nodes => NL,
                     Block => Precon_Block);
            end;

            --  Flowgraph for postconditions and right hand sides of
            --  contract cases.
            declare
               NL             : Union_Lists.List := Union_Lists.Empty_List;
               Postconditions : Node_Lists.List;
            begin
               for Refined in Boolean loop
                  Postconditions := Get_Postcondition_Expressions
                    (FA.Analyzed_Entity,
                     Refined);

                  for Postcondition of Postconditions loop
                     Do_Postcondition (Postcondition,
                                       FA,
                                       Connection_Map,
                                       The_Context);
                     NL.Append (Union_Id (Postcondition));
                  end loop;
               end loop;
               Join (FA    => FA,
                     CM    => Connection_Map,
                     Nodes => NL,
                     Block => Postcon_Block);
            end;

         when Kind_Task =>
            --  No pre or post here.
            null;

         when Kind_Package | Kind_Package_Body =>
            --  Flowgraph for initial_condition aspect
            declare
               Spec_E         : constant Entity_Id :=
                 (if Ekind (FA.Analyzed_Entity) = E_Package
                  then FA.Analyzed_Entity
                  else Spec_Entity (FA.Analyzed_Entity));
               NL             : Union_Lists.List := Union_Lists.Empty_List;
               Postconditions : constant Node_Lists.List :=
                 Get_Postcondition_Expressions (Spec_E,
                                                False);
            begin
               for Postcondition of Postconditions loop
                  Do_Postcondition (Postcondition,
                                    FA,
                                    Connection_Map,
                                    The_Context);
                  NL.Append (Union_Id (Postcondition));
               end loop;
               Join (FA    => FA,
                     CM    => Connection_Map,
                     Nodes => NL,
                     Block => Postcon_Block);
            end;

      end case;

      --  Produce flowgraphs for the body and link to start, helper
      --  end and end vertex.
      case FA.Kind is
         when Kind_Subprogram | Kind_Entry =>
            Do_Subprogram_Or_Block (Body_N, FA, Connection_Map, The_Context);

            --  Connect up all the dots...
            Linkup (FA,
                    FA.Start_Vertex,
                    Precon_Block.Standard_Entry);
            Linkup (FA,
                    Precon_Block.Standard_Exits,
                    Connection_Map (Union_Id (Body_N)).Standard_Entry);
            Linkup (FA,
                    Connection_Map (Union_Id (Body_N)).Standard_Exits,
                    FA.Helper_End_Vertex);
            Linkup (FA,
                    FA.Helper_End_Vertex,
                    Postcon_Block.Standard_Entry);
            Linkup (FA,
                    Postcon_Block.Standard_Exits,
                    FA.End_Vertex);

         when Kind_Task =>
            Do_Subprogram_Or_Block (Body_N, FA, Connection_Map, The_Context);

            Linkup (FA,
                    FA.Start_Vertex,
                    Connection_Map (Union_Id (Body_N)).Standard_Entry);
            Linkup (FA,
                    Connection_Map (Union_Id (Body_N)).Standard_Exits,
                    FA.Helper_End_Vertex);
            Linkup (FA,
                    FA.Helper_End_Vertex,
                    FA.End_Vertex);

         when Kind_Package | Kind_Package_Body =>
            declare
               UL   : Union_Lists.List := Union_Lists.Empty_List;
               Prev : Union_Id;
            begin
               if Present (Visible_Declarations (Spec_N)) then
                  Process_Statement_List (Visible_Declarations (Spec_N),
                                          FA, Connection_Map, The_Context);

                  UL.Append (Union_Id (Visible_Declarations (Spec_N)));
               end if;

               --  Ok, we need a copy of all variables from the spec +
               --  initializes. Although this is somewhat
               --  out-of-place, this is the only place we can
               --  assemble them easily without re-doing a lot of the
               --  hard work we've done so far.
               FA.Visible_Vars := FA.All_Vars or Package_Writes;

               if Present (Private_Declarations (Spec_N)) then
                  Process_Statement_List (Private_Declarations (Spec_N),
                                          FA, Connection_Map, The_Context);
                  UL.Append (Union_Id (Private_Declarations (Spec_N)));
               end if;

               if FA.Kind = Kind_Package_Body then
                  Do_Subprogram_Or_Block (Body_N,
                                          FA, Connection_Map, The_Context);
                  UL.Append (Union_Id (Body_N));
               end if;

               Prev := Union_Id (Empty);
               Linkup (FA,
                       FA.Start_Vertex,
                       Connection_Map (UL.First_Element).Standard_Entry);
               for X of UL loop
                  if Prev /= Union_Id (Empty) then
                     Linkup (FA,
                             Connection_Map (Prev).Standard_Exits,
                             Connection_Map (X).Standard_Entry);
                  end if;
                  Prev := X;
               end loop;
               Linkup (FA,
                       Connection_Map (UL.Last_Element).Standard_Exits,
                       FA.Helper_End_Vertex);
               Linkup (FA,
                       FA.Helper_End_Vertex,
                       Postcon_Block.Standard_Entry);
               Linkup (FA,
                       Postcon_Block.Standard_Exits,
                       FA.End_Vertex);

            end;
      end case;

      --  Label all vertices that are part of exceptional execution paths.
      Mark_Exceptional_Paths (FA);
      Prune_Exceptional_Paths (FA);

      --  Make sure we will be able to produce the post-dominance frontier
      --  even if we have dead code remaining.
      Separate_Dead_Paths (FA);

      --  Simplify graph by removing all null vertices.
      Simplify_CFG (FA);

      --  Assemble the set of directly called subprograms.
      for V of FA.CFG.Get_Collection (Flow_Graphs.All_Vertices) loop
         FA.Direct_Calls.Union (FA.Atr (V).Subprograms_Called);
      end loop;
      pragma Assert (for all E of FA.Direct_Calls => Nkind (E) in N_Entity);

      --  In GG mode, we now assemble a list of globals and subprograms (and
      --  retroactively make some initial and final vertices).
      if FA.Generating_Globals then
         declare
            Known_Vars : constant Flow_Id_Sets.Set :=
              To_Entire_Variables (FA.All_Vars);
         begin
            for V of FA.CFG.Get_Collection (Flow_Graphs.All_Vertices) loop
               declare
                  Atr  : constant V_Attributes     := FA.Atr (V);
                  Vars : constant Flow_Id_Sets.Set :=
                    To_Entire_Variables (Atr.Variables_Used or
                                           Atr.Variables_Defined);
               begin
                  for Var of Vars loop
                     if not Synthetic (Var)
                       and then not Known_Vars.Contains (Var)
                       and then not Is_Discriminant (Var)
                     then
                        FA.GG.Globals.Include (Get_Direct_Mapping_Id (Var));
                     end if;
                  end loop;
               end;
            end loop;
         end;

         for E of FA.GG.Globals loop
            Create_Initial_And_Final_Vertices
              (Direct_Mapping_Id (E),
               (if Ekind (E) in E_In_Parameter | E_Constant
                then Mode_In
                else Mode_In_Out),
               False, FA);

            --  Collect unsynchronized accesses by excluding states and objects
            --  that are synchronized or are Part_Of single concurrent types.
            if not (Is_Synchronized_Object (E)
                    or else Is_Synchronized_State (E)
                    or else Is_Part_Of_Concurrent_Object (E))
            then
               FA.Tasking (Unsynch_Accesses).Include (E);
            end if;
         end loop;

         for E of FA.Direct_Calls loop
            declare
               F : constant Flow_Id := Direct_Mapping_Id (E);
               V : Flow_Graphs.Vertex_Id;
               A : V_Attributes;
            begin
               if FA.CFG.Get_Vertex (Change_Variant (F, Initial_Value)) =
                 Flow_Graphs.Null_Vertex
               then
                  --  If the 'Initial and 'Final vertices do not
                  --  already exist then we create them.

                  --  Setup the n'initial vertex.
                  A := Make_Variable_Attributes (FA    => FA,
                                                 F_Ent => Change_Variant
                                                   (F, Initial_Value),
                                                 Mode  => Mode_In_Out,
                                                 E_Loc => E);

                  Add_Vertex
                    (FA,
                     Change_Variant (F, Initial_Value),
                     A,
                     V);
                  Linkup (FA, V, FA.Start_Vertex);

                  Create_Record_Tree (Change_Variant (F, Initial_Value),
                                      A,
                                      FA);

                  --  Setup the n'final vertex.
                  Add_Vertex
                    (FA,
                     Change_Variant (F, Final_Value),
                     Make_Variable_Attributes (FA    => FA,
                                               F_Ent => Change_Variant
                                                 (F, Final_Value),
                                               Mode  => Mode_In_Out,
                                               E_Loc => E),
                     V);
                  Linkup (FA, FA.End_Vertex, V);
               end if;
            end;
         end loop;
      end if;

      --  Note if this is a subprogram with no effects.
      if FA.Kind = Kind_Subprogram then
         FA.No_Effects := True;
         for F of FA.All_Vars loop
            declare
               V : constant Flow_Graphs.Vertex_Id :=
                 FA.CFG.Get_Vertex (Change_Variant (F, Final_Value));
            begin
               pragma Assert (V /= Flow_Graphs.Null_Vertex);
               if FA.Atr.Element (V).Is_Export then
                  FA.No_Effects := False;
                  exit;
               end if;
            end;
         end loop;
      end if;

      --  Finally, we need to make sure that all extra checks for folded
      --  functions have been processed.
      pragma Assert (The_Context.Folded_Function_Checks.Length = 0);
   end Create;

end Flow.Control_Flow_Graph;
