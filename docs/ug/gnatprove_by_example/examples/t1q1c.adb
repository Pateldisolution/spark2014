package body T1Q1C
is

  procedure Increment (X : in out Integer)
  is
  begin
     X := X + 1;
  end Increment;

  procedure Add2 (X : in out Integer)
  is
  begin
     Increment (X);
     Increment (X);
  end Add2;

end T1Q1C;
