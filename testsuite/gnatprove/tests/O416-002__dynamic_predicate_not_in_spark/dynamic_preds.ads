package Dynamic_Preds is

   function Get return access Integer is (new Integer);

   subtype Bad is Natural with Dynamic_Predicate => Get /= null;

   type Bad_Pair is record
      A : Bad;
      B : Bad;
   end record;

   type Bad_Array is array (1 .. 2) of Bad;

   procedure Do_Nothing (X : Bad) with SPARK_Mode;
   procedure Do_Nothing (X : Bad_Pair) with SPARK_Mode;
   procedure Do_Nothing (X : Bad_Array) with SPARK_Mode;

   package Local
     with SPARK_Mode
   is
      function Get return access Integer is (new Integer);

      subtype Bad is Natural with Dynamic_Predicate => Get /= null;

      type Bad_Pair is record
         A : Bad;
         B : Bad;
      end record;

      type Bad_Array is array (1 .. 2) of Bad;

      procedure Do_Nothing (X : Bad) with SPARK_Mode;
      procedure Do_Nothing (X : Bad_Pair) with SPARK_Mode;
      procedure Do_Nothing (X : Bad_Array) with SPARK_Mode;
   end Local;

end Dynamic_Preds;
