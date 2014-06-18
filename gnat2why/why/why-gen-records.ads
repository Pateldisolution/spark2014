------------------------------------------------------------------------------
--                                                                          --
--                            GNAT2WHY COMPONENTS                           --
--                                                                          --
--                      W H Y - G E N - R E C O R D S                       --
--                                                                          --
--                                 S p e c                                  --
--                                                                          --
--                       Copyright (C) 2010-2014, AdaCore                   --
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
-- gnat2why is maintained by AdaCore (http://www.adacore.com)               --
--                                                                          --
------------------------------------------------------------------------------

with Types;         use Types;
with Why.Ids;       use Why.Ids;
with Why.Sinfo;     use Why.Sinfo;
with Gnat2Why.Util; use Gnat2Why.Util;

package Why.Gen.Records is
   --  This package encapsulates the encoding of Ada records into Why. This
   --  also includes records with variant parts.

   procedure Declare_Conversion_Check_Function
     (Theory : W_Theory_Declaration_Id;
      E      : Entity_Id;
      Root   : Entity_Id);
   --  generate the program function which is used to insert subtype
   --  discriminant checks

   procedure Declare_Ada_Record
     (P       : Why_Section;
      Theory  : W_Theory_Declaration_Id;
      E       : Entity_Id);
   --  Emit all necessary Why3 declarations to support Ada records. This also
   --  supports variant records.

   function New_Ada_Record_Access
     (Ada_Node : Node_Id;
      Domain   : EW_Domain;
      Name     : W_Expr_Id;
      Field    : Entity_Id;
      Ty       : Entity_Id)
      return W_Expr_Id;
   --  Generate a Why3 expression that corresponds to the access to an Ada
   --  record field. Emit all necessary checks.

   function New_Ada_Record_Check_For_Field
     (Ada_Node : Node_Id := Empty;
      Domain   : EW_Domain;
      Name     : W_Expr_Id;
      Field    : Entity_Id;
      Ty       : Entity_Id)
      return W_Expr_Id;
   --  Generate a Why3 expression that corresponds to the cases where a record
   --  field is present in an Ada record.

   function New_Ada_Record_Update
     (Ada_Node : Node_Id;
      Domain   : EW_Domain;
      Name     : W_Expr_Id;
      Field    : Entity_Id;
      Value    : W_Expr_Id) return W_Expr_Id;
   --  Generate a Why3 expression that corresponds to the update to an Ada
   --  record field. Emit all necessary checks.
   --  Note that this function does not generate an assignment, instead it
   --  returns a functional update. In the case of simple records, it will look
   --  like
   --    { name with field = value }
   --  The assignment, if required, needs to be generated by the caller.

   function New_Is_Constrained_Access
     (Ada_Node : Node_Id := Empty;
      Domain   : EW_Domain;
      Name     : W_Expr_Id;
      Ty       : Entity_Id)
      return W_Expr_Id;
   --  Generate a Why3 expression that corresponds to an access to the
   --  additional field introduced in records for the 'Constrained attribute.

   function New_Is_Constrained_Update
     (Ada_Node : Node_Id := Empty;
      Domain   : EW_Domain;
      Name     : W_Expr_Id;
      Value    : W_Expr_Id;
      Ty       : Entity_Id)
      return W_Expr_Id;
   --  Generate a Why3 expression that corresponds to an update to the
   --  additional field introduced in records for the 'Constrained attribute.

   function Insert_Subtype_Discriminant_Check
     (Ada_Node : Node_Id;
      Check_Ty : Entity_Id;
      Expr     : W_Prog_Id) return W_Prog_Id;
   --  Given a record subtype and an expression, add a call to the subtype
   --  discriminant check function, to generate a discriminant check.

   function Prepare_Args_For_Subtype_Check
     (Check_Ty : Entity_Id;
      Expr     : W_Expr_Id) return W_Expr_Array;
   --  Given a record type, compute the argument array that can be used
   --  together with its subtype check predicate of program function. The
   --  last argument is actually the given expression itself.

end Why.Gen.Records;
