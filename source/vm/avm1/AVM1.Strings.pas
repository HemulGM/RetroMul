unit AVM1.Strings;

interface

uses
  System.SysUtils, AVM1.Runtime;

function AVMStringForTrace(const Text: string): string;

function AVMStringCall(VM: TAVM1; const Name: string; O: TAVMObject; const Args: TArray<TAVMValue>): TAVMValue;

implementation

uses
  System.Math, System.Generics.Collections, System.StrUtils, SWF.Reader,
  AVM1.Coercion, AVM1.Names;

function AVMStringForTrace(const Text: string): string;
var
  I, UnitValue: Integer;
begin
  Result := Text;
  I := 1;
  while I <= Length(Result) do
  begin
    UnitValue := Ord(Result[I]);
    if (UnitValue >= $D800) and (UnitValue <= $DBFF) then
    begin
      if (I < Length(Result)) and (Ord(Result[I + 1]) >= $DC00) and (Ord(Result[I + 1]) <= $DFFF) then
        Inc(I)
      else
        Result[I] := Char($FFFD);
    end
    else if (UnitValue >= $DC00) and (UnitValue <= $DFFF) then
      Result[I] := Char($FFFD);
    Inc(I);
  end;
end;

function StringIndex(Index, Count: Integer; Wrap: Boolean): Integer;
begin
  if Index < 0 then
  begin
    if Wrap then
      Result := Max(0, Count + Int64(Index))
    else
      Result := 0;
  end
  else
    Result := Min(Index, Count);
end;

function FindUnits(VM: TAVM1; const Text, Pattern: string; Start, Limit: Integer; Last: Boolean): Integer;
var
  Failure: TArray<Integer>;
  I, J, PatternLength: Integer;
begin
  Result := -1;
  PatternLength := Length(Pattern);
  if Start > Limit then
    Exit;
  if PatternLength = 0 then
  begin
    if Last then
      Result := Limit
    else
      Result := Start;
    Exit;
  end;
  if PatternLength > Limit - Start then
    Exit;
  { A prefix table keeps repeated-pattern searches linear in UCS-2 units.
    It preserves the source algorithm's exact first/last match boundaries. }
  SetLength(Failure, PatternLength);
  J := 0;
  for I := 1 to PatternLength - 1 do
  begin
    VM.ChargeWork(1);
    while (J > 0) and (Pattern[I + 1] <> Pattern[J + 1]) do
      J := Failure[J - 1];
    if Pattern[I + 1] = Pattern[J + 1] then
      Inc(J);
    Failure[I] := J;
  end;
  J := 0;
  for I := Start to Limit - 1 do
  begin
    VM.ChargeWork(1);
    while (J > 0) and (Text[I + 1] <> Pattern[J + 1]) do
      J := Failure[J - 1];
    if Text[I + 1] = Pattern[J + 1] then
      Inc(J);
    if J = PatternLength then
    begin
      Result := I - PatternLength + 1;
      if not Last then
        Exit;
      J := Failure[J - 1];
    end;
  end;
end;

function SplitString(VM: TAVM1; O: TAVMObject; const Args: TArray<TAVMValue>): TAVMValue;
var
  Text, Delimiter: string;
  Limit, Offset, Found, I: Integer;
  Parts: TList<TAVMValue>;

  function Arg(Index: Integer): TAVMValue;
  begin
    Result := Default(TAVMValue);
    if Index < Length(Args) then
      Result := Args[Index];
  end;

  procedure AddPart(const Text: string);
  begin
    if Parts.Count >= 65536 then
      raise ESWFError.Create('AVM1 array iteration limit');
    VM.ChargeWork(1);
    Parts.Add(TAVMValue.Str(Text));
  end;

begin
  Text := VM.CoerceString(TAVMValue.Ref(O));
  Limit := High(Integer);
  if Arg(1).Kind <> avUndefined then
    Limit := Max(0, AVMToInt32(VM.CoerceNumber(Arg(1))));
  if Arg(0).Kind = avUndefined then
  begin
    if VM.SWFVersion = 5 then
      Delimiter := ','
    else
      Exit(TAVMValue.Ref(VM.CreateArray([TAVMValue.Str(Text)])));
  end
  else
    Delimiter := VM.CoerceString(Arg(0));
  if (VM.SWFVersion = 5) and (Delimiter = '') then
    Exit(TAVMValue.Ref(VM.CreateArray([TAVMValue.Str(Text)])));
  Parts := TList<TAVMValue>.Create;
  try
    if Delimiter = '' then
      for I := 1 to Min(Length(Text), Limit) do
        AddPart(Text[I])
    else
    begin
      Offset := 1;
      while Parts.Count < Limit do
      begin
        Found := PosEx(Delimiter, Text, Offset);
        if Found = 0 then
        begin
          AddPart(Copy(Text, Offset, MaxInt));
          Break;
        end;
        AddPart(Copy(Text, Offset, Found - Offset));
        Offset := Found + Length(Delimiter);
      end;
    end;
    Result := TAVMValue.Ref(VM.CreateArray(Parts.ToArray));
  finally
    Parts.Free;
  end;
end;

function AVMStringCall(VM: TAVM1; const Name: string; O: TAVMObject; const Args: TArray<TAVMValue>): TAVMValue;
var
  Text, Pattern, Part: string;
  Start, Finish, Index, Count, I, CodeUnit: Integer;

  function Arg(Index: Integer): TAVMValue;
  begin
    Result := Default(TAVMValue);
    if Index < Length(Args) then
      Result := Args[Index];
  end;

begin
  Result := Default(TAVMValue);
  if Name = 'String.split' then
    Exit(SplitString(VM, O, Args));
  if (Name = 'String.toString') or (Name = 'String.valueOf') then
  begin
    if (O <> nil) and O.IsBoxed and (O.PrimitiveValue.Kind = avString) then
      Result := O.PrimitiveValue;
    Exit;
  end;
  if Name = 'String.fromCharCode' then
  begin
    Text := '';
    for I := 0 to High(Args) do
    begin
      VM.ChargeWork(1);
      CodeUnit := AVMToInt32(VM.CoerceNumber(Args[I])) and $FFFF;
      if CodeUnit = 0 then
        Break;
      Text := Text + Char(CodeUnit);
      if Length(Text) > 1048576 then
        raise ESWFError.Create('AVM1 string result limit');
    end;
    Exit(TAVMValue.Str(Text));
  end;
  if (Length(Args) = 0) and ((Name = 'String.slice') or (Name = 'String.substr') or
    (Name = 'String.substring')) then
    Exit;
  Text := VM.CoerceString(TAVMValue.Ref(O));
  Count := Length(Text);
  if Name = 'String.toLowerCase' then
  begin
    VM.ChargeWork(Count);
    Exit(TAVMValue.Str(AVMLowerName(Text)));
  end;
  if Name = 'String.toUpperCase' then
  begin
    VM.ChargeWork(Count);
    Exit(TAVMValue.Str(AVMUpperName(Text)));
  end;
  if (Name = 'String.charAt') or (Name = 'String.charCodeAt') then
  begin
    Index := AVMToInt32(VM.CoerceNumber(Arg(0)));
    if (Index >= 0) and (Index < Count) then
    begin
      if Name = 'String.charAt' then
        Exit(TAVMValue.Str(Copy(Text, Index + 1, 1)));
      Exit(TAVMValue.Num(Ord(Text[Index + 1])));
    end;
    if Name = 'String.charAt' then
      Exit(TAVMValue.Str(''));
    if (Index >= 0) and (VM.SWFVersion = 5) then
      Exit(TAVMValue.Num(0));
    Exit(TAVMValue.Num(NaN));
  end;
  if Name = 'String.concat' then
  begin
    for I := 0 to High(Args) do
    begin
      VM.ChargeWork(1);
      Part := VM.CoerceString(Args[I]);
      if Length(Part) > 1048576 - Length(Text) then
        raise ESWFError.Create('AVM1 string result limit');
      Text := Text + Part;
    end;
    Exit(TAVMValue.Str(Text));
  end;
  if (Name = 'String.indexOf') or (Name = 'String.lastIndexOf') then
  begin
    if Length(Args) = 0 then
      Exit;
    Pattern := VM.CoerceString(Args[0]);
    if Name = 'String.indexOf' then
    begin
      Start := 0;
      if (Length(Args) > 1) and (Args[1].Kind <> avUndefined) then
        Start := Max(0, AVMToInt32(VM.CoerceNumber(Args[1])));
      Exit(TAVMValue.Num(FindUnits(VM, Text, Pattern, Start, Count, False)));
    end;
    Finish := Count;
    if (Length(Args) > 1) and (Args[1].Kind <> avUndefined) then
    begin
      Index := AVMToInt32(VM.CoerceNumber(Args[1]));
      if Index < 0 then
        Exit(TAVMValue.Num(-1));
      Finish := Integer(Min(Int64(Count), Int64(Index) + Length(Pattern)));
    end;
    Exit(TAVMValue.Num(FindUnits(VM, Text, Pattern, 0, Finish, True)));
  end;
  if (Name = 'String.slice') or (Name = 'String.substr') or (Name = 'String.substring') then
  begin
    Start := StringIndex(AVMToInt32(VM.CoerceNumber(Args[0])), Count, Name <> 'String.substring');
    if Name = 'String.substr' then
    begin
      Index := Count;
      if (Length(Args) > 1) and (Args[1].Kind <> avUndefined) then
        Index := AVMToInt32(VM.CoerceNumber(Args[1]));
      Finish := StringIndex(AVMToInt32(Start + Double(Index)), Count, True);
    end
    else
    begin
      Finish := Count;
      if (Length(Args) > 1) and (Args[1].Kind <> avUndefined) then
        Finish := StringIndex(AVMToInt32(VM.CoerceNumber(Args[1])), Count, Name = 'String.slice');
    end;
    if (Name = 'String.substring') and (Finish < Start) then
    begin
      Index := Start;
      Start := Finish;
      Finish := Index;
    end;
    if Finish <= Start then
      Exit(TAVMValue.Str(''));
    Exit(TAVMValue.Str(Copy(Text, Start + 1, Finish - Start)));
  end;
  raise ESWFError.Create('Unsupported AVM1 string method: ' + Name);
end;

end.

