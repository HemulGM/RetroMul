unit NES.MiraclePianoDevice;

interface

uses
  NES.State;

const
  MIRACLE_FIRST_NOTE = 36;
  MIRACLE_LAST_NOTE = 84;
  MIRACLE_PEDAL = 49;
  MIRACLE_VOLUME_UP = 50;
  MIRACLE_VOLUME_DOWN = 51;
  MIRACLE_PIANO = 52;
  MIRACLE_HARPSICHORD = 53;
  MIRACLE_ORGAN = 54;
  MIRACLE_VIBRAPHONE = 55;
  MIRACLE_ELECTRIC_PIANO = 56;
  MIRACLE_SYNTH = 57;

type
  TMiracleKey = 0..57;

  TMiracleKeys = set of TMiracleKey;

  // Controller port 1 transports MIDI, MSB first. A short OUT0 pulse
  // polls one byte (ready bit + eight inverted bits); a long pulse sends it.
  // Protocol references: nesdev.org/wiki/Miracle_Piano and Nintaco's
  // documented Miracle keyboard implementation. The synthesizer is approximate.
  TMiraclePianoDevice = class
  private
    type
      TPortState = (Idle, Strobe, Receive, Transmit);

      TVoice = record
        Active, Held: Boolean;
        Channel, Note, Patch, Velocity: Byte;
        Phase, Level: Double;
      end;
  private
    FConnected: Boolean;
    FHostKeys, FScreenKeys, FAppliedKeys: TMiracleKeys;
    FQueue: array[0..2047] of Byte;
    FHead, FTail, FCount: Integer;
    FState: TPortState;
    FStrobeCycle: UInt64;
    FOutputBit, FTxByte: Byte;
    FTxBits, FRxBits: Integer;
    FRxByte: Byte;
    FStatus, FDataCount: Byte;
    FData: array[0..1] of Byte;
    FSysEx: array[0..15] of Byte;
    FSysExCount: Integer;
    FInSysEx, FLocalControl: Boolean;
    FVolume: Byte;
    FPatches: array[0..15] of Byte;
    FSustain: array[0..15] of Boolean;
    FVoices: array[0..31] of TVoice;
    procedure Enqueue(const Bytes: array of Byte);
    procedure ReceiveMidi(Value: Byte);
    procedure HandleSysEx;
    procedure NoteOn(Channel, Note, Velocity: Byte);
    procedure NoteOff(Channel, Note: Byte);
    procedure Sustain(Channel: Byte; Down: Boolean);
    procedure AllNotesOff(Channel: Byte);
  public
    constructor Create;
    procedure Reset;
    procedure SerializeState(State: TNesStateArchive);
    procedure Write(Value: Byte; Cycle: UInt64);
    function Read: Byte;
    procedure ReadOtherPort;
    procedure SetHostKey(Code: UInt32; Pressed: Boolean);
    class function HostKey(Code: UInt32): Integer; static;
    procedure SetScreenKeys(const Keys: TMiracleKeys);
    function GetPressedKeys: TMiracleKeys;
    procedure ClearInput;
    // Called only on the worker, after copying host input at a frame boundary.
    procedure ApplyKeys(const Keys: TMiracleKeys);
    procedure MixAudio(var Samples: array of SmallInt; Count, SampleRate: Integer);
    property Connected: Boolean read FConnected write FConnected;
    property Volume: Byte read FVolume;
  end;

implementation

uses
  System.Math, System.UITypes;

constructor TMiraclePianoDevice.Create;
begin
  inherited;
  Reset;
end;

procedure TMiraclePianoDevice.Reset;
begin
  FState := Idle;
  FStrobeCycle := 0;
  FOutputBit := 0;
  FTxByte := 0;
  FTxBits := 0;
  FRxBits := 0;
  FRxByte := 0;
  FHead := 0;
  FTail := 0;
  FCount := 0;
  FStatus := 0;
  FDataCount := 0;
  FSysExCount := 0;
  FInSysEx := False;
  FLocalControl := True;
  FVolume := 100;
  FAppliedKeys := [];
  FillChar(FPatches, SizeOf(FPatches), 0);
  FillChar(FSustain, SizeOf(FSustain), 0);
  FillChar(FVoices, SizeOf(FVoices), 0);
end;

procedure TMiraclePianoDevice.Enqueue(const Bytes: array of Byte);
begin
  // Keep packets whole, even if an application stops polling the keyboard.
  if Length(Bytes) > Length(FQueue) - FCount then
    Exit;
  for var B in Bytes do
  begin
    FQueue[FHead] := B;
    FHead := (FHead + 1) mod Length(FQueue);
    Inc(FCount);
  end;
end;

procedure TMiraclePianoDevice.Write(Value: Byte; Cycle: UInt64);
begin
  if not FConnected then
    Exit;
  FOutputBit := Value and 1;
  case FState of
    Idle, Receive:
      if FOutputBit <> 0 then
      begin
        FStrobeCycle := Cycle;
        FState := Strobe;
      end;
    Strobe:
      if (Cycle >= FStrobeCycle) and (Cycle - FStrobeCycle >= 40) then
      begin
        FTxBits := 0;
        FTxByte := 0;
        FState := Transmit;
      end
      else if FOutputBit = 0 then
      begin
        FRxBits := 0;
        FRxByte := 0;
        if FCount > 0 then
        begin
          FRxByte := FQueue[FTail];
          FTail := (FTail + 1) mod Length(FQueue);
          Dec(FCount);
          FRxBits := 9;
        end;
        FState := Receive;
      end;
  end;
end;

function TMiraclePianoDevice.Read: Byte;
begin
  Result := 0;
  if not FConnected then
    Exit;
  if FState = Receive then
  begin
    if FRxBits = 9 then
      Result := 1
    else if FRxBits > 0 then
      Result := 1 xor ((FRxByte shr (FRxBits - 1)) and 1);
    if FRxBits > 0 then
      Dec(FRxBits);
  end
  else if FState = Transmit then
  begin
    FTxByte := Byte((Integer(FTxByte) shl 1) or FOutputBit);
    Inc(FTxBits);
    if FTxBits = 8 then
    begin
      ReceiveMidi(FTxByte);
      FState := Idle;
    end;
  end;
end;

procedure TMiraclePianoDevice.ReadOtherPort;
begin
  // Menu polling aborts an unfinished serial transaction.
  FState := Idle;
end;

procedure TMiraclePianoDevice.NoteOn(Channel, Note, Velocity: Byte);
begin
  if Velocity = 0 then
  begin
    NoteOff(Channel, Note);
    Exit;
  end;
  var Slot := -1;
  var Quietest := 0;
  for var I := 0 to High(FVoices) do
  begin
    if FVoices[I].Active and (FVoices[I].Channel = Channel) and
      (FVoices[I].Note = Note) then
    begin
      Slot := I;
      Break;
    end;
    if not FVoices[I].Active then
      Slot := I;
    if FVoices[I].Level < FVoices[Quietest].Level then
      Quietest := I;
  end;
  if Slot < 0 then
    Slot := Quietest;
  FVoices[Slot] := Default(TVoice);
  FVoices[Slot].Active := True;
  FVoices[Slot].Held := True;
  FVoices[Slot].Channel := Channel;
  FVoices[Slot].Note := Note;
  FVoices[Slot].Patch := FPatches[Channel];
  FVoices[Slot].Velocity := Velocity;
  FVoices[Slot].Level := 1;
end;

procedure TMiraclePianoDevice.NoteOff(Channel, Note: Byte);
begin
  for var I := 0 to High(FVoices) do
    if (FVoices[I].Channel = Channel) and (FVoices[I].Note = Note) then
      FVoices[I].Held := False;
end;

procedure TMiraclePianoDevice.Sustain(Channel: Byte; Down: Boolean);
begin
  FSustain[Channel and 7] := Down;
  FSustain[(Channel and 7) or 8] := Down;
end;

procedure TMiraclePianoDevice.AllNotesOff(Channel: Byte);
begin
  for var I := 0 to High(FVoices) do
    if (FVoices[I].Channel and 7) = (Channel and 7) then
      FVoices[I].Active := False;
end;

procedure TMiraclePianoDevice.HandleSysEx;
begin
  if (FSysExCount < 6) or (FSysEx[0] <> 0) or (FSysEx[1] <> 0) or
    (FSysEx[2] <> $42) or (FSysEx[3] <> 1) then
    Exit;
  case FSysEx[4] of
    $04:
      Enqueue([$F0, 0, 0, $42, 1, 5, 1, 0, $F7]);
    $06:
      if FSysExCount = 9 then
      begin
        FPatches[FSysEx[5] and 7] := FSysEx[6];
        FPatches[(FSysEx[5] and 7) or 8] := FSysEx[7];
      end;
  end;
end;

procedure TMiraclePianoDevice.ReceiveMidi(Value: Byte);
begin
  // MIDI realtime messages can appear between any two data bytes.
  if Value >= $F8 then
  begin
    if Value = $FF then
    begin
      FillChar(FVoices, SizeOf(FVoices), 0);
      FillChar(FSustain, SizeOf(FSustain), 0);
      FLocalControl := True;
      FStatus := 0;
      FDataCount := 0;
      FInSysEx := False;
    end;
    Exit;
  end;
  if Value = $F0 then
  begin
    FInSysEx := True;
    FSysExCount := 0;
    FStatus := 0;
    Exit;
  end;
  if FInSysEx then
  begin
    if Value = $F7 then
    begin
      // Count includes the terminator; it has no place in the data buffer.
      Inc(FSysExCount);
      HandleSysEx;
      FInSysEx := False;
    end
    else if Value < $80 then
    begin
      if FSysExCount < Length(FSysEx) then
        FSysEx[FSysExCount] := Value;
      if FSysExCount <= Length(FSysEx) then
        Inc(FSysExCount);
    end
    else
      FInSysEx := False;
    Exit;
  end;
  if Value >= $80 then
  begin
    FStatus := Value;
    FDataCount := 0;
    Exit;
  end;
  if (FStatus < $80) or (FStatus >= $F0) then
    Exit;
  FData[FDataCount] := Value;
  Inc(FDataCount);
  var Kind := FStatus and $F0;
  var Needed := 2;
  if Kind in [$C0, $D0] then
    Needed := 1;
  if FDataCount < Needed then
    Exit;
  FDataCount := 0;
  var Channel := FStatus and 7;
  case Kind of
    $80, $90:
      begin
        if (FData[0] >= 60) and (Channel <> 1) then
          Channel := Channel or 8;
        if (Kind = $80) or (FData[1] = 0) then
          NoteOff(Channel, FData[0])
        else
          NoteOn(Channel, FData[0], FData[1]);
      end;
    $B0:
      case FData[0] of
        7:
          FVolume := FData[1];
        64:
          Sustain(Channel, FData[1] >= 64);
        120, 123:
          AllNotesOff(Channel);
        122:
          FLocalControl := FData[1] <> 0;
      end;
    $C0:
      begin
        FPatches[Channel] := FData[0];
        FPatches[Channel or 8] := FData[0];
      end;
  end;
end;

procedure TMiraclePianoDevice.ApplyKeys(const Keys: TMiracleKeys);
const
  Patches: array[0..5] of Byte = (0, 4, 6, 29, 2, 68);
begin
  if not FConnected then
    Exit;
  var Changed := (Keys - FAppliedKeys) + (FAppliedKeys - Keys);
  FAppliedKeys := Keys;
  for var Key in Changed do
  begin
    var Down := Key in Keys;
    if Key < MIRACLE_PEDAL then
    begin
      var Note := Byte(MIRACLE_FIRST_NOTE + Key);
      var Velocity: Byte := 0;
      if Down then
        Velocity := 100;
      Enqueue([$90, Note, Velocity]);
      if FLocalControl then
      begin
        var Channel: Byte := 0;
        if Note >= 60 then
          Channel := 8;
        if Down then
          NoteOn(Channel, Note, Velocity)
        else
          NoteOff(Channel, Note);
      end;
    end
    else if Key = MIRACLE_PEDAL then
    begin
      var Value: Byte := 0;
      if Down then
        Value := 127;
      Enqueue([$B0, 64, Value]);
      if FLocalControl then
        Sustain(0, Down);
    end
    else
    begin
      var Button: Byte;
      if Key >= MIRACLE_PIANO then
        Button := Key - MIRACLE_PIANO
      else if Key = MIRACLE_VOLUME_UP then
        Button := 6
      else
        Button := 7;
      if Down then
        Button := Button or 8;
      Enqueue([$F0, 0, 0, $42, 1, 1, Button, $F7]);
      if Down and FLocalControl then
        if Key >= MIRACLE_PIANO then
        begin
          FPatches[0] := Patches[Key - MIRACLE_PIANO];
          FPatches[8] := FPatches[0];
        end
        else if Key = MIRACLE_VOLUME_UP then
          FVolume := Min(127, FVolume + 13)
        else
          FVolume := Max(0, FVolume - 13);
    end;
  end;
end;

class function TMiraclePianoDevice.HostKey(Code: UInt32): Integer;
const
  Codes: array[0..28] of UInt32 = (vkZ, vkS, vkX, vkD, vkC, vkV,
    vkG, vkB, vkH, vkN, vkJ, vkM, vkQ, vk2, vkW, vk3, vkE, vkR,
    vk5, vkT, vk6, vkY, vk7, vkU, vkI, vk9, vkO, vk0, vkP);
begin
  for var I := 0 to High(Codes) do
    if Code = Codes[I] then
      Exit(12 + I); // C3..E5, chromatic piano layout.
  case Code of
    vkSpace:
      Exit(MIRACLE_PEDAL);
    vkAdd:
      Exit(MIRACLE_VOLUME_UP);
    vkSubtract:
      Exit(MIRACLE_VOLUME_DOWN);
    vkF1..vkF6:
      Exit(MIRACLE_PIANO + Integer(Code) - vkF1);
  end;
  Result := -1;
end;

procedure TMiraclePianoDevice.SetHostKey(Code: UInt32; Pressed: Boolean);
begin
  var Key := HostKey(Code);
  if Key < 0 then
    Exit;
  if Pressed then
    Include(FHostKeys, TMiracleKey(Key))
  else
    Exclude(FHostKeys, TMiracleKey(Key));
end;

procedure TMiraclePianoDevice.SetScreenKeys(const Keys: TMiracleKeys);
begin
  FScreenKeys := Keys;
end;

function TMiraclePianoDevice.GetPressedKeys: TMiracleKeys;
begin
  Result := FHostKeys + FScreenKeys;
end;

procedure TMiraclePianoDevice.ClearInput;
begin
  FHostKeys := [];
  FScreenKeys := [];
end;

procedure TMiraclePianoDevice.MixAudio(var Samples: array of SmallInt; Count, SampleRate: Integer);
begin
  if not FConnected or (SampleRate <= 0) then
    Exit;
  // Portable additive voices avoid a platform MIDI driver and its extra latency.
  var ReleaseFactor := Exp(-1 / (0.07 * SampleRate));
  var DecayFactor := Exp(-1 / (1.8 * SampleRate));
  var Steps: array[0..31] of Double;
  for var V := 0 to High(FVoices) do
    Steps[V] := 2 * Pi * 440 * Power(2, (Integer(FVoices[V].Note) - 69) / 12) / SampleRate;
  for var I := 0 to Min(Count, Length(Samples)) - 1 do
  begin
    var Value: Double := 0;
    for var V := 0 to High(FVoices) do
      if FVoices[V].Active then
      begin
        var P := FVoices[V].Phase;
        var Tone: Double;
        case FVoices[V].Patch of
          4:
            Tone := (Sin(P) + 0.45 * Sin(2 * P) + 0.25 * Sin(3 * P)) / 1.7;
          6, 7, 77..79:
            Tone := (Sin(P) + 0.5 * Sin(2 * P) + 0.3 * Sin(4 * P)) / 1.8;
          29..31:
            Tone := (Sin(P) + 0.25 * Sin(3 * P)) / 1.25;
          68..76, 80..95:
            Tone := (Sin(P) + 0.3 * Sin(2 * P)) / 1.3;
        else
          Tone := (Sin(P) + 0.3 * Sin(2 * P) + 0.1 * Sin(3 * P)) / 1.4;
        end;
        Value := Value + Tone * FVoices[V].Level * FVoices[V].Velocity / 127;
        FVoices[V].Phase := P + Steps[V];
        if FVoices[V].Phase >= 2 * Pi then
          FVoices[V].Phase := FVoices[V].Phase - 2 * Pi;
        if not FVoices[V].Held and not FSustain[FVoices[V].Channel] then
          FVoices[V].Level := FVoices[V].Level * ReleaseFactor
        else if not (FVoices[V].Patch in [6, 7, 68..95]) then
          FVoices[V].Level := FVoices[V].Level * DecayFactor;
        if FVoices[V].Level < 0.0001 then
          FVoices[V].Active := False;
      end;
    Samples[I] := EnsureRange(Round(Samples[I] + Value * 2200 * FVolume / 127), -32768, 32767);
  end;
end;

procedure TMiraclePianoDevice.SerializeState(State: TNesStateArchive);
begin
  State.Field(FState, SizeOf(FState));
  State.Field(FStrobeCycle, SizeOf(FStrobeCycle));
  State.Field(FOutputBit, SizeOf(FOutputBit));
  State.Field(FTxByte, SizeOf(FTxByte));
  State.Field(FTxBits, SizeOf(FTxBits));
  State.Field(FRxBits, SizeOf(FRxBits));
  State.Field(FRxByte, SizeOf(FRxByte));
  State.Field(FQueue, SizeOf(FQueue));
  State.Field(FHead, SizeOf(FHead));
  State.Field(FTail, SizeOf(FTail));
  State.Field(FCount, SizeOf(FCount));
  State.Field(FStatus, SizeOf(FStatus));
  State.Field(FDataCount, SizeOf(FDataCount));
  State.Field(FData, SizeOf(FData));
  State.Field(FSysEx, SizeOf(FSysEx));
  State.Field(FSysExCount, SizeOf(FSysExCount));
  State.Field(FInSysEx, SizeOf(FInSysEx));
  State.Field(FLocalControl, SizeOf(FLocalControl));
  State.Field(FVolume, SizeOf(FVolume));
  State.Field(FPatches, SizeOf(FPatches));
  State.Field(FSustain, SizeOf(FSustain));
  State.Field(FAppliedKeys, SizeOf(FAppliedKeys));
  // Write voice fields individually; record alignment differs on Win32/Win64.
  for var I := 0 to High(FVoices) do
  begin
    State.Field(FVoices[I].Active, SizeOf(Boolean));
    State.Field(FVoices[I].Held, SizeOf(Boolean));
    State.Field(FVoices[I].Channel, SizeOf(Byte));
    State.Field(FVoices[I].Note, SizeOf(Byte));
    State.Field(FVoices[I].Patch, SizeOf(Byte));
    State.Field(FVoices[I].Velocity, SizeOf(Byte));
    State.Field(FVoices[I].Phase, SizeOf(Double));
    State.Field(FVoices[I].Level, SizeOf(Double));
  end;
end;

end.

