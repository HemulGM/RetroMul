unit J2ME.Form.Layout;

interface

uses
  JVM.Runtime, J2ME.Item.Layout;

type
  TJ2MEItemBox = record
    Ref, X, Y, Width, Height, Row, Layout: Integer;
    Metrics: TJ2MEItemMetrics;
  end;

  TJ2MEFormLayout = class
  private
    FVM: TJVM;
    FScreen, FWidth, FHeight, FVersion: Integer;
  public
    Boxes: TArray<TJ2MEItemBox>;
    TotalHeight: Integer;
    constructor Create(VM: TJVM);
    procedure Clear;
    procedure Update(Screen, Width, Height: Integer);
    function Find(Item: Integer): Integer;
  end;

implementation

uses
  System.SysUtils, System.Math, System.Generics.Collections, J2ME.Forms,
  J2ME.UI.Data;

{$Q-}{$R-}

constructor TJ2MEFormLayout.Create(VM: TJVM);
begin
  inherited Create;
  FVM := VM;
end;

procedure TJ2MEFormLayout.Clear;
begin
  FScreen := 0;
  Boxes := nil;
end;

function TJ2MEFormLayout.Find(Item: Integer): Integer;
begin
  for var I := 0 to High(Boxes) do
    if Boxes[I].Ref = Item then
      Exit(I);
  Result := -1;
end;

procedure TJ2MEFormLayout.Update(Screen, Width, Height: Integer);
type
  TRow = record
    First, Last, Height, Alignment: Integer;
    Stretch: Boolean;
  end;
var
  Rows: TList<TRow>;
  First, Used, Alignment: Integer;
  Y: Int64;

  procedure FinishRow(Last: Integer);
  var
    Row: TRow;
    Extra, Weight, StretchCount: Int64;
  begin
    if Last < First then
      Exit;
    Row := Default(TRow);
    Row.First := First;
    Row.Last := Last;
    Row.Alignment := Alignment;
    Extra := Max(0, Width - Used);
    Weight := 0;
    for var I := First to Last do
      if (Boxes[I].Layout and $400) <> 0 then
        Inc(Weight, Max(0, Boxes[I].Metrics.PreferredWidth - Boxes[I].Width));
    var Given := Min(Extra, Weight);
    var Left := Given;
    for var I := First to Last do
      if (Boxes[I].Layout and $400) <> 0 then
      begin
        var Need := Int64(Max(0, Boxes[I].Metrics.PreferredWidth - Boxes[I].Width));
        var Part := Int64(0);
        if Weight > 0 then
          Part := Min(Need, Given * Need div Weight);
        Part := Min(Part, Left);
        Inc(Boxes[I].Width, Integer(Part));
        Dec(Left, Part);
      end;
    for var I := First to Last do
      if (Left > 0) and ((Boxes[I].Layout and $400) <> 0) then
      begin
        var Part := Min(Left, Int64(Max(0, Boxes[I].Metrics.PreferredWidth - Boxes[I].Width)));
        Inc(Boxes[I].Width, Integer(Part));
        Dec(Left, Part);
      end;
    Dec(Extra, Given - Left);
    StretchCount := 0;
    for var I := First to Last do
      if (Boxes[I].Layout and $800) <> 0 then
        Inc(StretchCount);
    if StretchCount > 0 then
      for var I := First to Last do
        if (Boxes[I].Layout and $800) <> 0 then
        begin
          var Part := Extra div StretchCount;
          Inc(Boxes[I].Width, Integer(Part));
          Dec(Extra, Part);
          Dec(StretchCount);
        end;
    var X := 0;
    if Alignment = 2 then
      X := Integer(Extra)
    else if Alignment = 3 then
      X := Integer(Extra div 2);
    for var I := First to Last do
    begin
      var Box := Boxes[I];
      Box.Metrics := J2MEItemMetrics(FVM, Box.Ref, Width, Box.Width);
      Box.Height := Box.Metrics.PreferredHeight;
      if (Box.Layout and $1000) <> 0 then
        Box.Height := Box.Metrics.MinimumHeight;
      Box.X := X;
      Inc(X, Box.Width);
      Box.Row := Rows.Count;
      Row.Height := Max(Row.Height, Box.Height);
      Row.Stretch := Row.Stretch or ((Box.Layout and $2000) <> 0);
      Boxes[I] := Box;
    end;
    Rows.Add(Row);
    First := Last + 1;
    Used := 0;
  end;

begin
  Width := Max(1, Width);
  Height := Max(1, Height);
  var O := FVM.GetObject(Screen);
  var Version := UIInt(O, 'version');
  if (FScreen = Screen) and (FWidth = Width) and (FHeight = Height) and (FVersion = Version) then
    Exit;
  FScreen := 0;
  var Items := J2MEFormItems(FVM, Screen);
  SetLength(Boxes, Length(Items.Elements));
  Rows := TList<TRow>.Create;
  try
    First := 0;
    Used := 0;
    Alignment := 1;
    for var I := 0 to High(Boxes) do
    begin
      var Ref := Items.Elements[I].AsRef;
      var Item := FVM.GetObject(Ref);
      var Layout := UIInt(Item, 'layout');
      var NewAlignment := Layout and 3;
      var BreakBefore := (Layout and $100) <> 0;
      var Kind := UIInt(Item, 'itemKind');
      if (Kind in [4, 5, 6, 7]) and ((Layout and $4000) = 0) then
        BreakBefore := True;
      var LabelText := UIString(FVM, UIRef(Item, 'label'));
      var Text := UIString(FVM, UIRef(Item, 'text'));
      if (LabelText <> '') or ((Text <> '') and (Kind = 1) and (Text[1] = #10)) then
        BreakBefore := True;
      if ((NewAlignment <> 0) and (NewAlignment <> Alignment)) or BreakBefore then
        FinishRow(I - 1);
      if NewAlignment <> 0 then
        Alignment := NewAlignment;
      Boxes[I] := Default(TJ2MEItemBox);
      Boxes[I].Ref := Ref;
      Boxes[I].Layout := Layout;
      Boxes[I].Metrics := J2MEItemMetrics(FVM, Ref, Width, -1);
      var W := Boxes[I].Metrics.PreferredWidth;
      if (Layout and $400) <> 0 then
        W := Boxes[I].Metrics.MinimumWidth;
      W := Min(Width, W);
      if (Used > 0) and (W > Width - Used) then
        FinishRow(I - 1);
      Boxes[I].Width := W;
      Inc(Used, W);
      var BreakAfter := (Layout and $200) <> 0;
      if (Kind in [4, 5, 6, 7]) and ((Layout and $4000) = 0) then
        BreakAfter := True;
      if (Kind = 1) and (Text <> '') and (Text[Length(Text)] = #10) then
        BreakAfter := True;
      if BreakAfter then
        FinishRow(I);
    end;
    FinishRow(High(Boxes));
    Y := 0;
    var StretchCount := 0;
    for var Row in Rows do
    begin
      Inc(Y, Int64(Row.Height) + Ord(Row.Height > 0) * 4);
      if Row.Stretch then
        Inc(StretchCount);
    end;
    var Extra := Max(Int64(0), Int64(Height) - Y);
    Y := 0;
    for var R := 0 to Rows.Count - 1 do
    begin
      var Row := Rows[R];
      if Row.Stretch then
      begin
        var Part := Extra div StretchCount;
        Row.Height := Integer(Min(Int64(MaxInt), Int64(Row.Height) + Part));
        Dec(Extra, Part);
        Dec(StretchCount);
      end;
      for var I := Row.First to Row.Last do
      begin
        var Box := Boxes[I];
        if (Box.Layout and $2000) <> 0 then
          Box.Height := Row.Height;
        var Offset := Row.Height - Box.Height;
        if (Box.Layout and $30) = $10 then
          Offset := 0
        else if (Box.Layout and $30) = $30 then
          Offset := Offset div 2;
        Box.Y := Integer(Min(Int64(MaxInt), Y + Offset));
        Boxes[I] := Box;
      end;
      Inc(Y, Int64(Row.Height) + Ord(Row.Height > 0) * 4);
    end;
    TotalHeight := Integer(Min(Int64(MaxInt), Y));
    FScreen := Screen;
    FWidth := Width;
    FHeight := Height;
    FVersion := Version;
  finally
    Rows.Free;
  end;
end;

end.

