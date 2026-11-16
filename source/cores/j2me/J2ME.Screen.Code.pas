unit J2ME.Screen.Code;

interface

uses
  J2ME.Suite, J2ME.Device;

function TryJ2MECodeScreen(Suite: TJ2MESuite; MIDletIndex: Integer; out Size: TJ2MEScreenSize; out Evidence: TArray<string>): Boolean;

implementation

uses
  System.SysUtils, System.Generics.Collections, JVM.Types, JVM.ClassFile,
  JVM.Bytecode, Core.Storage;

{$Q-}{$R-}

type
  TValueKind = (Unknown, IntegerValue, DisplayGraphics, CanvasObject);

  TValue = record
    Kind: TValueKind;
    Number: Integer;
    class function Int(N: Integer): TValue; static;
    class function OfKind(K: TValueKind): TValue; static;
  end;

  TCall = record
    Method: TJVMMethod;
    Locals: TArray<TValue>;
  end;

  TAnalyzer = class
  private
    FClasses: TObjectDictionary<string, TJVMClass>;
    FCalls: TList<TCall>;
    FSeen, FReachableClasses: TDictionary<string, Boolean>;
    FRects: TDictionary<string, TArray<string>>;
    FVariableViewport: Boolean;
    FSteps: Integer;
    function Canvas(const Name: string): Boolean;
    function Method(const Owner, Name, Desc: string): TJVMMethod;
    procedure Queue(M: TJVMMethod; const Args: TArray<TValue>);
    function Scan(const Call: TCall; ReturnOnly: Boolean = False): TValue;
  public
    constructor Create;
    destructor Destroy; override;
    function Detect(Suite: TJ2MESuite; Index: Integer; out Size: TJ2MEScreenSize; out Evidence: TArray<string>): Boolean;
  end;

class function TValue.Int(N: Integer): TValue;
begin
  Result := Default(TValue);
  Result.Kind := IntegerValue;
  Result.Number := N;
end;

class function TValue.OfKind(K: TValueKind): TValue;
begin
  Result := Default(TValue);
  Result.Kind := K;
end;

constructor TAnalyzer.Create;
begin
  inherited;
  FClasses := TObjectDictionary<string, TJVMClass>.Create([doOwnsValues]);
  FCalls := TList<TCall>.Create;
  FSeen := TDictionary<string, Boolean>.Create;
  FReachableClasses := TDictionary<string, Boolean>.Create;
  FRects := TDictionary<string, TArray<string>>.Create;
end;

destructor TAnalyzer.Destroy;
begin
  FRects.Free;
  FReachableClasses.Free;
  FSeen.Free;
  FCalls.Free;
  FClasses.Free;
  inherited;
end;

function TAnalyzer.Canvas(const Name: string): Boolean;
begin
  var N := Name;
  for var I := 0 to 31 do
  begin
    if (N = 'javax/microedition/lcdui/Canvas') or (N = 'com/nokia/mid/ui/FullCanvas') or
      (N = 'javax/microedition/lcdui/game/GameCanvas') then
      Exit(True);
    var C: TJVMClass;
    if not FClasses.TryGetValue(N, C) then
      Break;
    N := C.SuperName;
  end;
  Result := False;
end;

function TAnalyzer.Method(const Owner, Name, Desc: string): TJVMMethod;
begin
  var N := Owner;
  for var I := 0 to 31 do
  begin
    var C: TJVMClass;
    if not FClasses.TryGetValue(N, C) then
      Break;
    Result := C.FindMethod(Name, Desc);
    if Result <> nil then
      Exit;
    N := C.SuperName;
  end;
  Result := nil;
end;

procedure TAnalyzer.Queue(M: TJVMMethod; const Args: TArray<TValue>);
begin
  if (M = nil) or (Length(M.Code) = 0) then
    Exit;
  if M.MaxLocals > 4096 then
    raise EAbort.Create('analysis budget');
  var Key := M.Owner.Name + '.' + M.Name + M.Descriptor;
  for var V in Args do
    Key := Key + ':' + Ord(V.Kind).ToString + ',' + V.Number.ToString;
  if FSeen.ContainsKey(Key) then
    Exit;
  FSeen.Add(Key, True);
  if FCalls.Count >= 512 then
    raise EAbort.Create('analysis budget');
  var C := Default(TCall);
  C.Method := M;
  SetLength(C.Locals, M.MaxLocals);
  var Slot := 0;
  for var I := 0 to High(Args) do
  begin
    if Slot >= Length(C.Locals) then
      Exit;
    C.Locals[Slot] := Args[I];
    Inc(Slot);
    var A := I - Ord((M.Access and JVM_ACC_STATIC) = 0);
    if (A >= 0) and (A < Length(M.Signature.Arguments)) and
      ((M.Signature.Arguments[A] = 'J') or (M.Signature.Arguments[A] = 'D')) then
      Inc(Slot);
  end;
  FCalls.Add(C);
end;

function TAnalyzer.Scan(const Call: TCall; ReturnOnly: Boolean): TValue;
var
  M: TJVMMethod;
  PCs: TArray<Integer>;
  Mutated: TArray<Boolean>;
  Stores, LastStore: TArray<Integer>;
  FirstBranch: Integer;
  Flow: Boolean;
  Reachable: TArray<Boolean>;

  function U2(At: Integer): Integer;
  begin
    Result := (Integer(M.Code[At]) shl 8) or M.Code[At + 1];
  end;

  function StoreIndex(Op, At: Integer): Integer;
  begin
    Result := -1;
    if Op in [$36..$3A, $84] then
      Exit(M.Code[At + 1]);
    if Op in [$3B..$4E] then
      Exit((Op - $3B) mod 4);
  end;

  function Value(var At: Integer; Depth: Integer = 0): TValue;
  begin
    Result := Default(TValue);
    if At < 0 then
      Exit;
    if Depth > 32 then
    begin
      At := -1;
      Exit;
    end;
    Inc(FSteps);
    if FSteps > 300000 then
      raise EAbort.Create('analysis budget');
    var PC := PCs[At];
    var Op := M.Code[PC];
    Dec(At);
    if Op = $00 then
      Exit(Value(At, Depth + 1));
    if Op in [$02..$08] then
      Exit(TValue.Int(Op - $03));
    if Op = $10 then
      Exit(TValue.Int(ShortInt(M.Code[PC + 1])));
    if Op = $11 then
      Exit(TValue.Int(SmallInt(U2(PC + 1))));
    if Op in [$12, $13] then
    begin
      var Index := Integer(M.Code[PC + 1]);
      if Op = $13 then
        Index := U2(PC + 1);
      var C := M.Owner.Constant(Index);
      if C.Tag = 3 then
        Result := TValue.Int(Integer(C.Bits));
      Exit;
    end;
    if (Op in [$15..$19, $1A..$2D]) then
    begin
      var local: Integer;
      if Op in [$15..$19] then
        local := M.Code[PC + 1]
      else
        local := (Op - $1A) mod 4;
      if local >= Length(Call.Locals) then
        Exit;
      if not Mutated[local] then
        Exit(Call.Locals[local]);
      // A backwards slice cannot safely infer a local across a control-flow join.
      if Flow then
      begin
        if (Stores[local] = 1) and (LastStore[local] < FirstBranch) and (LastStore[local] < At + 1) then
        begin
          var Before := LastStore[local] - 1;
          Exit(Value(Before, Depth + 1));
        end;
        Exit;
      end;
      for var I := At downto 0 do
        if StoreIndex(M.Code[PCs[I]], PCs[I]) = local then
        begin
          var Before := I - 1;
          Exit(Value(Before, Depth + 1));
        end;
      Exit;
    end;
    if Op in [$B2, $B4] then
    begin
      var Owner, Name, Desc: string;
      M.Owner.MemberRef(U2(PC + 1), Owner, Name, Desc);
      if Op = $B4 then
        Value(At, Depth + 1);
      var C: TJVMClass;
      if FClasses.TryGetValue(Owner, C) then
        for var F in C.Fields do
          if (F.Name = Name) and (F.Descriptor = 'I') and (F.ConstantIndex <> 0) and ((F.Access and JVM_ACC_FINAL) <> 0) then
            Exit(TValue.Int(Integer(C.Constant(F.ConstantIndex, 3).Bits)));
      Exit;
    end;
    if Op in [$60, $64, $68, $6C, $70, $78, $7A, $7C, $7E, $80, $82] then
    begin
      var B := Value(At, Depth + 1);
      var A := Value(At, Depth + 1);
      if (A.Kind <> IntegerValue) or (B.Kind <> IntegerValue) then
        Exit;
      var N := 0;
      case Op of
        $60:
          N := A.Number + B.Number;
        $64:
          N := A.Number - B.Number;
        $68:
          N := A.Number * B.Number;
        $6C, $70:
          begin
            if (B.Number = 0) or ((A.Number = Low(Integer)) and (B.Number = -1)) then
              Exit;
            if Op = $6C then
              N := A.Number div B.Number
            else
              N := A.Number mod B.Number;
          end;
        $78:
          N := A.Number shl (B.Number and 31);
        $7A:
          begin
            var Shift := B.Number and 31;
            N := Integer(UInt32(A.Number) shr Shift);
            if (A.Number < 0) and (Shift > 0) then
              N := N or Integer(UInt32($FFFFFFFF) shl (32 - Shift));
          end;
        $7C:
          N := Integer(UInt32(A.Number) shr (B.Number and 31));
        $7E:
          N := A.Number and B.Number;
        $80:
          N := A.Number or B.Number;
        $82:
          N := A.Number xor B.Number;
      end;
      Exit(TValue.Int(N));
    end;
    if Op = $74 then
    begin
      Result := Value(At, Depth + 1);
      if Result.Kind = IntegerValue then
        Result.Number := -Result.Number;
      Exit;
    end;
    if Op in [$91..$93] then
    begin
      Result := Value(At, Depth + 1);
      if Result.Kind = IntegerValue then
        case Op of
          $91:
            Result.Number := ShortInt(Result.Number);
          $92:
            Result.Number := Word(Result.Number);
          $93:
            Result.Number := SmallInt(Result.Number);
        end;
      Exit;
    end;
    if Op in [$2E..$35] then
    begin
      Value(At, Depth + 1);
      Value(At, Depth + 1);
      Exit;
    end;
    if Op in [$B6..$B9] then
    begin
      var Owner, Name, Desc: string;
      M.Owner.MemberRef(U2(PC + 1), Owner, Name, Desc);
      var Signature := JVMMethodType(Desc);
      for var I := High(Signature.Arguments) downto 0 do
        Value(At, Depth + 1);
      var Receiver := Default(TValue);
      if Op <> $B8 then
        Receiver := Value(At, Depth + 1);
      if (Name = 'getGraphics') and (Desc = '()Ljavax/microedition/lcdui/Graphics;') and
        (Receiver.Kind = CanvasObject) and ((Owner = 'javax/microedition/lcdui/game/GameCanvas') or
        (Canvas(Owner) and (Method(Owner, Name, Desc) = nil))) then
        Result.Kind := DisplayGraphics;
      Exit;
    end;
    // Unknown expression boundaries must not expose earlier stack operands.
    At := -1;
  end;

begin
  Result := Default(TValue);
  M := Call.Method;
  var Map := JVMInstructionMap(M.Code, M.MaxLocals);
  PCs := nil;
  SetLength(Mutated, M.MaxLocals);
  SetLength(Stores, M.MaxLocals);
  SetLength(LastStore, M.MaxLocals);
  Flow := False;
  FirstBranch := MaxInt;
  var List := TList<Integer>.Create;
  try
    for var PC := 0 to High(M.Code) do
      if Map[PC] then
      begin
        Inc(FSteps);
        if FSteps > 300000 then
          raise EAbort.Create('analysis budget');
        var Op := M.Code[PC];
        if (Op in [$C4, $A8, $A9, $C9]) then
        begin
          FVariableViewport := True;
          Exit;
        end;
        var Index := StoreIndex(Op, PC);
        if (Index >= 0) and (Index < Length(Mutated)) then
        begin
          Mutated[Index] := True;
          Inc(Stores[Index]);
          LastStore[Index] := List.Count;
        end;
        if (Op in [$99..$AB, $C6..$C9]) then
        begin
          Flow := True;
          if FirstBranch = MaxInt then
            FirstBranch := List.Count;
        end;
        List.Add(PC);
      end;
    PCs := List.ToArray;
  finally
    List.Free;
  end;
  // Follow instruction edges, never interpreting operand bytes as instructions.
  SetLength(Reachable, Length(M.Code));
  var Pending := TQueue<Integer>.Create;
  var ByPC: TArray<Integer>;
  SetLength(ByPC, Length(M.Code));
  for var I := 0 to High(PCs) do
    ByPC[PCs[I]] := I + 1;
  var Mark: TProc<Integer> :=
    procedure(PC: Integer)
    begin
      if (PC < 0) or (PC >= Length(Reachable)) or (ByPC[PC] = 0) then
        Exit;
      if not Reachable[PC] then
      begin
        Reachable[PC] := True;
        Pending.Enqueue(PC);
      end;
    end;
  var S4: TFunc<Integer, Integer> :=
    function(At: Integer): Integer
    begin
      Result := Integer((UInt32(M.Code[At]) shl 24) or (UInt32(M.Code[At + 1]) shl 16) or (UInt32(M.Code[At + 2]) shl 8) or M.Code[At + 3]);
    end;
  try
    Mark(0);
    while Pending.Count > 0 do
    begin
      Inc(FSteps);
      if FSteps > 300000 then
        raise EAbort.Create('analysis budget');
      var PC := Pending.Dequeue;
      var I := ByPC[PC] - 1;
      var Op := M.Code[PC];
      for var H in M.Handlers do
      begin
        Inc(FSteps);
        if FSteps > 300000 then
          raise EAbort.Create('analysis budget');
        if (PC >= H.StartPC) and (PC < H.EndPC) then
          Mark(H.HandlerPC);
      end;
      if Op in [$AC..$B1, $BF] then
        Continue;
      if Op = $A7 then
      begin
        Mark(PC + SmallInt(U2(PC + 1)));
        Continue;
      end;
      if Op = $C8 then
      begin
        Mark(PC + S4(PC + 1));
        Continue;
      end;
      if Op in [$AA, $AB] then
      begin
        var At := (PC + 4) and not 3;
        Mark(PC + S4(At));
        if Op = $AA then
        begin
          var Count := S4(At + 8) - S4(At + 4) + 1;
          Inc(At, 12);
          for var J := 0 to Count - 1 do
            Mark(PC + S4(At + J * 4));
        end
        else
        begin
          var Count := S4(At + 4);
          Inc(At, 8);
          for var J := 0 to Count - 1 do
            Mark(PC + S4(At + J * 8 + 4));
        end;
        Continue;
      end;
      if Op in [$99..$A6, $C6, $C7] then
        Mark(PC + SmallInt(U2(PC + 1)));
      if I < High(PCs) then
        Mark(PCs[I + 1]);
    end;
  finally
    Mark := nil;
    S4 := nil;
    Pending.Free;
  end;
  // Only straight-line getters are used as hard bounds.
  if ReturnOnly then
  begin
    if Flow then
      Exit;
    var Found := False;
    for var I := 0 to High(PCs) do
      if Reachable[PCs[I]] and (M.Code[PCs[I]] = $AC) then
      begin
        var At: Integer := I - 1;
        var V := Value(At);
        if (V.Kind <> IntegerValue) or (Found and (V.Number <> Result.Number)) then
          Exit(Default(TValue));
        Result := V;
        Found := True;
      end;
    Exit;
  end;
  for var I := 0 to High(PCs) do
  begin
    Inc(FSteps);
    if FSteps > 300000 then
      raise EAbort.Create('analysis budget');
    var PC := PCs[I];
    var Op := M.Code[PC];
    if not Reachable[PC] then
      Continue;
    if not (Op in [$B6..$B9]) then
      Continue;
    var Owner, Name, Desc: string;
    M.Owner.MemberRef(U2(PC + 1), Owner, Name, Desc);
    var Signature := JVMMethodType(Desc);
    var Args: TArray<TValue>;
    SetLength(Args, Length(Signature.Arguments) + Ord(Op <> $B8));
    var At: Integer := I - 1;
    for var A := High(Args) downto 0 do
      Args[A] := Value(At);
    var Display := False;
    for var A in Args do
      Display := Display or (A.Kind = DisplayGraphics);
    if not Display then
      Continue;
    if (Owner = 'javax/microedition/lcdui/Graphics') and (Length(Args) = 5) and
      ((Name = 'fillRect') or (Name = 'setClip')) and (Args[0].Kind = DisplayGraphics) and
      (Args[1].Kind = IntegerValue) and (Args[1].Number = 0) and
      (Args[2].Kind = IntegerValue) and (Args[2].Number = 0) then
    begin
      var W := Args[3];
      var H := Args[4];
      if (W.Kind <> IntegerValue) or (H.Kind <> IntegerValue) then
      begin
        if ((W.Kind <> IntegerValue) or (W.Number >= 64)) and
          ((H.Kind <> IntegerValue) or (H.Number >= 64)) then
          FVariableViewport := True;
        Continue;
      end;
      if Name <> 'fillRect' then
        Continue;
      for var P in TJ2MEScreenSize.Presets do
        if (P.Width = W.Number) and (P.Height = H.Number) then
        begin
          var E: TArray<string>;
          FRects.TryGetValue(P.ToString, E);
          var Description := M.Owner.Name + '.' + M.Name + M.Descriptor + ' pc=' + PC.ToString;
          if Length(E) < 8 then
            E := E + [Description];
          FRects.AddOrSetValue(P.ToString, E);
        end;
    end
    else
      Queue(Method(Owner, Name, Desc), Args);
  end;
end;

function TAnalyzer.Detect(Suite: TJ2MESuite; Index: Integer; out Size: TJ2MEScreenSize; out Evidence: TArray<string>): Boolean;
begin
  Result := False;
  Size := Default(TJ2MEScreenSize);
  Evidence := nil;
  var Total := 0;
  var Names := Suite.ClassNames;
  if Length(Names) > 512 then
    Exit;
  for var Name in Names do
  begin
    TStorage.CheckReadCancelled;
    var Bytes := Suite.LoadClass(Name);
    Inc(Total, Length(Bytes));
    if Total > 4 * 1024 * 1024 then
      Exit;
    try
      var C := TJVMClass.Parse(Bytes);
      FClasses.Add(Name, C);
    except
      on E: EJVMFormatError do
        Continue;
    end;
  end;
  var Work := TList<string>.Create;
  try
    Work.Add(Suite.MIDlet(Index).ClassName);
    var I := 0;
    while I < Work.Count do
    begin
      var Name := Work[I];
      Inc(I);
      if FReachableClasses.ContainsKey(Name) then
        Continue;
      FReachableClasses.Add(Name, True);
      var C: TJVMClass;
      if FClasses.TryGetValue(Name, C) then
        for var CP in C.Constants do
          if CP.Tag = 7 then
          begin
            var Ref := C.UTF8(CP.A);
            if FClasses.ContainsKey(Ref) then
            begin
              if Work.Count >= 16384 then
                raise EAbort.Create('analysis budget');
              Work.Add(Ref);
            end;
          end;
    end;
  finally
    Work.Free;
  end;
  var Bounds: TDictionary<string, Boolean> := TDictionary<string, Boolean>.Create;
  try
    for var C in FClasses.Values do
      if FReachableClasses.ContainsKey(C.Name) and Canvas(C.Name) then
      begin
        var W := Method(C.Name, 'getWidth', '()I');
        var H := Method(C.Name, 'getHeight', '()I');
        if (W <> nil) and (H <> nil) then
        begin
          var A := Default(TCall);
          A.Method := W;
          SetLength(A.Locals, W.MaxLocals);
          var WV := Scan(A, True);
          A.Method := H;
          SetLength(A.Locals, H.MaxLocals);
          var HV := Scan(A, True);
          if (WV.Kind = IntegerValue) and (HV.Kind = IntegerValue) and
            (WV.Number >= 64) and (WV.Number <= 1024) and (HV.Number >= 64) and (HV.Number <= 1024) then
            Bounds.AddOrSetValue(TJ2MEScreenSize.Create(WV.Number, HV.Number).ToString, True);
        end;
        Queue(Method(C.Name, 'paint', '(Ljavax/microedition/lcdui/Graphics;)V'),
          [TValue.OfKind(CanvasObject), TValue.OfKind(DisplayGraphics)]);
        Queue(Method(C.Name, 'run', '()V'), [TValue.OfKind(CanvasObject)]);
      end;
    if Bounds.Count = 1 then
    begin
      for var Key in Bounds.Keys do
        TJ2MEScreenSize.TryParse(Key, Size);
      Evidence := ['constant Canvas.getWidth/getHeight overrides'];
      Exit(True);
    end;
    if Bounds.Count > 1 then
      Exit;
  finally
    Bounds.Free;
  end;
  var I := 0;
  while I < FCalls.Count do
  begin
    TStorage.CheckReadCancelled;
    // Scan may append calls and reallocate the list. Keep an owning record copy
    // rather than a const reference into its backing array while it grows.
    var Context := FCalls[I];
    Scan(Context);
    Inc(I);
  end;
  if FVariableViewport or (FRects.Count <> 1) then
    Exit;
  for var Pair in FRects do
  begin
    TJ2MEScreenSize.TryParse(Pair.Key, Size);
    Evidence := Pair.Value;
  end;
  Result := True;
end;

function TryJ2MECodeScreen(Suite: TJ2MESuite; MIDletIndex: Integer; out Size: TJ2MEScreenSize; out Evidence: TArray<string>): Boolean;
begin
  var A := TAnalyzer.Create;
  try
    try
      Result := A.Detect(Suite, MIDletIndex, Size, Evidence);
    except
      on E: EJVMError do
      begin
        Result := False;
        Evidence := ['unsupported or malformed bytecode'];
      end;
      on E: EAbort do
      begin
        TStorage.CheckReadCancelled;
        Result := False;
        Evidence := ['analysis budget reached'];
      end;
    end;
  finally
    A.Free;
  end;
end;

end.

