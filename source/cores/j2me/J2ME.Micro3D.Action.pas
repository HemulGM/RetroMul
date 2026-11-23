unit J2ME.Micro3D.Action;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime, J2ME.Suite;

const
  Micro3DActionName = 'com/mascotcapsule/micro3d/v3/ActionTable';
  Micro3DActionType = 'L' + Micro3DActionName + ';';
  Micro3DPoseKey = 'com/mascotcapsule/micro3d/v3/Figure.$pose:[F';

procedure InstallJ2MEMicro3DAction(VM: TJVM);

function InvokeJ2MEMicro3DAction(VM: TJVM; Suite: TJ2MESuite; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

procedure SetMicro3DPosture(VM: TJVM; Figure, Table: TJVMObject; BoneCount, Action, Frame: Integer; var Pattern: Integer);

implementation

uses
  System.Classes, System.Math, System.SysUtils, Java.Classes, J2ME.M3G.Math;

const
  MaxActionBytes = 8 * 1024 * 1024;
  HeaderSize = 28;
  PoseStride = 12;
  DataKey = Micro3DActionName + '.$data:[B';
  OffsetsKey = Micro3DActionName + '.$offsets:[I';

type
  TChannel = array[0..2] of Double;

  TMTRACursor = record
    Data: TBytes;
    Bytes: TJVMObject;
    Offset, Limit: Integer;
    function Reserve(Count: Integer): Integer;
    function ByteAt(Index: Integer): Integer;
    function WordAt(Index: Integer): Integer;
    function ShortAt(Index: Integer): Integer;
    function ReadByte: Integer;
    function ReadWord: Integer;
    function ReadShort: Integer;
    procedure Track(Components: Integer; Frame: Double; Evaluate: Boolean; var Values: TChannel);
  end;

procedure Require(Condition: Boolean; const MessageText: string);
begin
  if not Condition then
    raise EReadError.Create('MTRA: ' + MessageText);
end;

function TMTRACursor.Reserve(Count: Integer): Integer;
begin
  Require(Count <= Limit - Offset, 'truncated data');
  Result := Offset;
  Inc(Offset, Count);
end;

function TMTRACursor.ByteAt(Index: Integer): Integer;
begin
  if Bytes <> nil then
    Result := Bytes.ElementValues[Index].AsInt and $FF
  else
    Result := Data[Index];
end;

function TMTRACursor.WordAt(Index: Integer): Integer;
begin
  Result := ByteAt(Index) or (ByteAt(Index + 1) shl 8);
end;

function TMTRACursor.ShortAt(Index: Integer): Integer;
begin
  Result := WordAt(Index);
  if Result >= $8000 then
    Dec(Result, $10000);
end;

function TMTRACursor.ReadByte: Integer;
begin
  Result := ByteAt(Reserve(1));
end;

function TMTRACursor.ReadWord: Integer;
begin
  Result := WordAt(Reserve(2));
end;

function TMTRACursor.ReadShort: Integer;
begin
  Result := ShortAt(Reserve(2));
end;

procedure TMTRACursor.Track(Components: Integer; Frame: Double; Evaluate: Boolean; var Values: TChannel);
begin
  var Count := ReadWord;
  var Stride := (Components + 1) * 2;
  var Start := Reserve(Count * Stride);
  if not Evaluate then
  begin
    if Bytes = nil then
      for var I := 1 to Count - 1 do
        Require(WordAt(Start + (I - 1) * Stride) <= WordAt(Start + I * Stride), 'unordered key frames');
    Exit;
  end;
  if Count = 0 then
    Exit;
  var Low := 0;
  var High := Count;
  while Low < High do
  begin
    var Mid := (Low + High) div 2;
    if WordAt(Start + Mid * Stride) <= Frame then
      Low := Mid + 1
    else
      High := Mid;
  end;
  var Previous := Start + Max(0, Low - 1) * Stride;
  for var I := 0 to Components - 1 do
    Values[I] := ShortAt(Previous + 2 + I * 2);
  if (Low = 0) or (Low = Count) then
    Exit;
  var Next := Previous + Stride;
  var A := WordAt(Previous);
  var B := WordAt(Next);
  var Fraction := (Frame - A) / (B - A);
  for var I := 0 to Components - 1 do
    Values[I] := Values[I] + Fraction * (ShortAt(Next + 2 + I * 2) - Values[I]);
end;

function ReadBone(var Cursor: TMTRACursor; Frame: Double; Evaluate: Boolean): TM3GMatrix;
var
  MoveBy, Scale, Direction, Roll: TChannel;
begin
  Result := M3GIdentity;
  var Kind := Cursor.ReadByte;
  if Kind = 0 then
  begin
    for var I := 0 to PoseStride - 1 do
    begin
      var Value := Cursor.ReadShort;
      if (I and 3) = 3 then
        Result[I] := Value
      else
        Result[I] := Value / 4096;
    end;
    Exit;
  end;
  if Kind = 1 then
    Exit;
  Require(Kind in [2..6], 'unknown bone encoding');
  MoveBy := Default(TChannel);
  Roll := Default(TChannel);
  Scale := Default(TChannel);
  for var I := 0 to 2 do
    Scale[I] := 4096;
  Direction := Default(TChannel);
  Direction[2] := 4096;
  if Kind in [2, 6] then
    Cursor.Track(3, Frame, Evaluate, MoveBy)
  else if Kind = 3 then
    for var I := 0 to 2 do
      MoveBy[I] := Cursor.ReadShort;
  if Kind = 2 then
    Cursor.Track(3, Frame, Evaluate, Scale);
  Cursor.Track(3, Frame, Evaluate, Direction);
  if Kind in [2, 4, 6] then
    Cursor.Track(1, Frame, Evaluate, Roll)
  else if Kind = 3 then
    Roll[0] := Cursor.ReadShort;
  if not Evaluate then
    Exit;
  // The direction track maps the bone's local +Z to the new direction.
  // The roll and scale then operate in its local coordinate system.
  var Norm := Sqrt(Sqr(Direction[0]) + Sqr(Direction[1]) + Sqr(Direction[2]));
  if Norm > 0 then
  begin
    if Norm + Direction[2] > Norm * 1E-12 then
      M3GQuaternion(-Direction[1], Direction[0], 0, Norm + Direction[2], Result)
    else
    begin
      Result[5] := -1;
      Result[10] := -1;
    end;
  end;
  var Angle := Roll[0] * Pi / 2048;
  var SinRoll := Sin(Angle);
  var CosRoll := Cos(Angle);
  for var Row := 0 to 2 do
  begin
    var I := Row * 4;
    var X := Result[I];
    var Y := Result[I + 1];
    Result[I] := (X * CosRoll + Y * SinRoll) * Scale[0] / 4096;
    Result[I + 1] := (Y * CosRoll - X * SinRoll) * Scale[1] / 4096;
    Result[I + 2] := Result[I + 2] * Scale[2] / 4096;
    Result[I + 3] := MoveBy[Row];
  end;
end;

procedure StoreTable(VM: TJVM; O: TJVMObject; const Data: TBytes);
begin
  Require(Length(Data) <= MaxActionBytes, 'size limit exceeded');
  var Cursor := Default(TMTRACursor);
  Cursor.Data := Data;
  Cursor.Limit := Length(Data);
  Require(Cursor.ReadWord = $544D, 'invalid signature');
  var Version := Cursor.ReadWord;
  Require(Version in [2..5], 'unsupported version');
  var Count := Cursor.ReadWord;
  var BoneCount := Cursor.ReadWord;
  Cursor.Reserve(HeaderSize - Cursor.Offset);
  var MinActionBytes := 2 + BoneCount + 2 * Ord(Version >= 5);
  Require(Count <= (Cursor.Limit - Cursor.Offset) div MinActionBytes, 'invalid action count');
  var Offsets: TArray<Integer>;
  SetLength(Offsets, Count);
  for var I := 0 to Count - 1 do
  begin
    if VM.StopRequested then
      Exit;
    Offsets[I] := Cursor.Reserve(2);
    for var J := 0 to BoneCount - 1 do
      ReadBone(Cursor, 0, False);
    if Version >= 5 then
    begin
      var Events := Cursor.ReadWord;
      Cursor.Reserve(Events * 6);
    end;
  end;
  var Remaining := Cursor.Limit - Cursor.Offset;
  Require((Remaining = 0) or ((Version >= 4) and (Remaining = 20)), 'invalid trailer length');
  var Ref := VM.NewArray('[B', Length(Data));
  var Bytes := VM.GetObject(Ref);
  for var I := 0 to High(Data) do
    Bytes.ElementValues[I] := TJVMValue.Int(Data[I]);
  var IndexRef := VM.NewArray('[I', Count);
  var Index := VM.GetObject(IndexRef);
  for var I := 0 to High(Offsets) do
    Index.ElementValues[I] := TJVMValue.Int(Offsets[I]);
  O.Fields[DataKey] := TJVMValue.Ref(Ref);
  O.Fields[OffsetsKey] := TJVMValue.Ref(IndexRef);
end;

function TableIndex(VM: TJVM; Table: TJVMObject): TJVMObject;
begin
  var Ref := Table.Fields[OffsetsKey].AsRef;
  if Ref = 0 then
    VM.RaiseJava('java/lang/IllegalStateException', 'ActionTable is disposed');
  Result := VM.GetObject(Ref);
end;

function ActionOffset(VM: TJVM; Table: TJVMObject; Action: Integer): Integer;
begin
  var Index := TableIndex(VM, Table);
  if (Action < 0) or (Action >= Index.ElementCount) then
    VM.RaiseJava('java/lang/IllegalArgumentException', 'Action index');
  Result := Index.ElementValues[Action].AsInt;
end;

function TableCursor(VM: TJVM; Table: TJVMObject): TMTRACursor;
begin
  Result := Default(TMTRACursor);
  Result.Bytes := VM.GetObject(Table.Fields[DataKey].AsRef);
  Result.Limit := Result.Bytes.ElementCount;
end;

procedure SetMicro3DPosture(VM: TJVM; Figure, Table: TJVMObject; BoneCount, Action, Frame: Integer; var Pattern: Integer);
begin
  var Start := ActionOffset(VM, Table, Action);
  var Cursor := TableCursor(VM, Table);
  var TableBones := Cursor.WordAt(6);
  var Count := Min(TableBones, BoneCount);
  var Key := Max(0, Frame) / 65536.0;
  var PoseRef := 0;
  var PoseValue: TJVMValue;
  if Figure.Fields.TryGetValue(Micro3DPoseKey, PoseValue) then
    PoseRef := PoseValue.AsRef;
  if (PoseRef = 0) or (VM.GetObject(PoseRef).ElementCount <> Count * PoseStride) then
    PoseRef := VM.NewArray('[F', Count * PoseStride);
  var Pose := VM.GetObject(PoseRef);
  Cursor.Offset := Start + 2;
  for var Bone := 0 to TableBones - 1 do
  begin
    if VM.StopRequested then
      Exit;
    var Matrix := ReadBone(Cursor, Key, Bone < Count);
    if Bone < Count then
      for var I := 0 to PoseStride - 1 do
        Pose.ElementValues[Bone * PoseStride + I] := TJVMValue.Float(Matrix[I]);
  end;
  if Cursor.WordAt(2) >= 5 then
  begin
    var Changes := Cursor.ReadWord;
    var Latest := -1;
    for var I := 0 to Changes - 1 do
    begin
      var AtFrame := Cursor.ReadWord;
      var Low := Cursor.ReadWord;
      var High := Cursor.ReadWord;
      if (AtFrame <= Key) and (AtFrame >= Latest) then
      begin
        Latest := AtFrame;
        Pattern := Low or (High shl 16);
      end;
    end;
  end;
  Figure.Fields[Micro3DPoseKey] := TJVMValue.Ref(PoseRef);
end;

procedure InstallJ2MEMicro3DAction(VM: TJVM);
begin
  var Builder := TJavaClassBuilder.Create(Micro3DActionName, 'java/lang/Object');
  try
    Builder.Field('$data', '[B', JVM_ACC_PRIVATE);
    Builder.Field('$offsets', '[I', JVM_ACC_PRIVATE);
    Builder.JavaClass.AddNative('<init>', '([B)V');
    Builder.JavaClass.AddNative('<init>', '(Ljava/lang/String;)V');
    Builder.JavaClass.AddNative('dispose', '()V');
    for var Name in ['getNumAction', 'getNumActions'] do
      Builder.JavaClass.AddNative(Name, '()I');
    for var Name in ['getNumFrame', 'getNumFrames'] do
      Builder.JavaClass.AddNative(Name, '(I)I');
    for var Method in Builder.JavaClass.Methods do
      if Method.Name <> '<init>' then
        Method.Access := Method.Access or JVM_ACC_FINAL;
    VM.DefineClass(Builder.Detach);
  finally
    Builder.Free;
  end;
end;

function InvokeJ2MEMicro3DAction(VM: TJVM; Suite: TJ2MESuite; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
begin
  Result := Default(TJVMValue);
  var O := VM.GetObject(Args[0].AsRef);
  var Name := Method.Name;
  if Name = '<init>' then
  begin
    var Input := VM.GetObject(Args[1].AsRef);
    var Data: TBytes;
    if Method.Descriptor = '([B)V' then
    begin
      if Input.ElementCount > MaxActionBytes then
        VM.RaiseJava('java/lang/RuntimeException', 'MTRA size limit exceeded');
      SetLength(Data, Input.ElementCount);
      for var I := 0 to High(Data) do
        Data[I] := Byte(Input.ElementValues[I].AsInt and $FF);
    end
    else
    begin
      if (Input.Text = '') or not Suite.HasResource(Input.Text) then
        VM.RaiseJava('java/io/IOException', 'Missing action table: ' + Input.Text);
      try
        Data := Suite.ReadResource(Input.Text);
      except
        on E: EStreamError do
          VM.RaiseJava('java/io/IOException', E.Message);
      end;
    end;
    try
      StoreTable(VM, O, Data);
    except
      on E: EReadError do
        VM.RaiseJava('java/lang/RuntimeException', E.Message);
    end;
    Exit;
  end;
  if Name = 'dispose' then
  begin
    O.Fields[DataKey] := TJVMValue.Ref(0);
    O.Fields[OffsetsKey] := TJVMValue.Ref(0);
    Exit;
  end;
  if (Name = 'getNumAction') or (Name = 'getNumActions') then
    Exit(TJVMValue.Int(TableIndex(VM, O).ElementCount));
  if (Name = 'getNumFrame') or (Name = 'getNumFrames') then
  begin
    var Start := ActionOffset(VM, O, Args[1].AsInt);
    var Cursor := TableCursor(VM, O);
    Exit(TJVMValue.Int(Cursor.WordAt(Start) shl 16));
  end;
  raise EJVMUnsupported.Create(Micro3DActionName + '.' + Name + Method.Descriptor);
end;

end.

