package body P is
   procedure Shadow_Effect (P : in out Painting; D : Dot) is
      P_Old : constant Painting := P;
   begin
      for C in Color loop

         --  Loop invariant required to prove the postcondition

         pragma Assert
           (P.Plain = P_Old.Plain and then
             (for all J in Color'First .. Color'Pred (C) =>
               (if P.Plain (J) = D then P.Shadow (J) = D)));

         if P.Plain (C) = D then
            P.Shadow (C) := D;
         end if;
      end loop;
   end Shadow_Effect;

   procedure Shadow_Effect_2 (P : in out Painting; D : Dot) is
   begin
      Shadow_Effect (P, D);
   end Shadow_Effect_2;
end P;
