  var X0 := Int64(V0.X);
  var Y0 := Int64(V0.Y);
  var X1 := Int64(V1.X);
  var Y1 := Int64(V1.Y);
  var X2 := Int64(V2.X);
  var Y2 := Int64(V2.Y);
  var Area := (X1 - X0) * (Y2 - Y0) - (Y1 - Y0) * (X2 - X0);
  if Area = 0 then
    Exit;
  // Orient counter-clockwise in screen space (y down): make Area positive.
  var A0, A1, A2: PGEVertex;
  A0 := @V0;
  A1 := @V1;
  A2 := @V2;
  if Area < 0 then
  begin
    A1 := @V2;
    A2 := @V1;
    X1 := V2.X;
    Y1 := V2.Y;
    X2 := V1.X;
    Y2 := V1.Y;
    Area := -Area;
  end;
  var MinX := Min(X0, Min(X1, X2));
  var MaxX := Max(X0, Max(X1, X2));
  var MinY := Min(Y0, Min(Y1, Y2));
  var MaxY := Max(Y0, Max(Y1, Y2));
  // Pixel ranges whose centres can be inside.
  var PX1 := Integer((MinX - 8 + 15 + $100000) div 16) - $10000;
  var PX2 := Integer((MaxX - 8 + $100000) div 16) - $10000;
  var PY1 := Integer((MinY - 8 + 15 + $100000) div 16) - $10000;
  var PY2 := Integer((MaxY - 8 + $100000) div 16) - $10000;
  PX1 := Max(PX1, S.ScissorX1);
  PY1 := Max(PY1, Max(S.ScissorY1, S.BandY1));
  PX2 := Min(PX2, S.ScissorX2);
  PY2 := Min(PY2, Min(S.ScissorY2, S.BandY2));
  if (PX1 > PX2) or (PY1 > PY2) then
    Exit;
