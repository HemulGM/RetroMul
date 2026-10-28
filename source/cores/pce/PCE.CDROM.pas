unit PCE.CDROM;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, Core.CD.Disc, PCE.Cartridge;

type
  TPCESCSIPhase = (Idle, Command, DataIn, Status, MessageIn, Waiting);

  TPCECDState = record
    Phase: TPCESCSIPhase;
    Command: array[0..9] of Byte;
    Buffer: array[0..2047] of Byte;
    CommandCount, BufferSize, BufferPosition, Sector, SectorsRemaining, Delay: Integer;
    DataPort, StatusCode, IRQEnable, IRQPending, ResetPort: Byte;
    ACK, Request, BRAMLocked: Boolean;
    AudioStart, AudioEnd, AudioSector, AudioPosition, AudioMode: Integer;
    AudioPlaying, AudioPaused, ReadRight: Boolean;
    AudioLatch: SmallInt;
    ADAddress, ADRead, ADWrite, ADLength, ADSignal, ADStep, ADDMACycles: Integer;
    ADControl, ADRate, ADDMA, ADReadBuffer: Byte;
    ADNibble: Boolean;
    ADPhase, FadeCD, FadeAD, FadeRateCD, FadeRateAD: Double;
    FadeControl: Byte;
  end;

  TPCECDROM = class
  private
    FDisc: TCDDisc; // Shared disc reader; caller owns it.
    FState: TPCECDState;
    FBRAM: array[0..2047] of Byte;
    FADRAM: array[0..65535] of Byte;
    FAudio: TBytes;
    FSuper: Boolean;
    procedure Status(Code: Byte = 0);
    procedure DataReady;
    procedure Command;
    procedure Acknowledge;
    procedure NextSector;
    function AudioAddress: Integer;
    function DataByte: Byte;
    procedure ADWrite(Value: Byte);
  public
    constructor Create(Disc: TCDDisc; SuperCD: Boolean);
    procedure Reset;
    function Read(Address: Word): Byte;
    procedure Write(Address: Word; Value: Byte);
    procedure Advance(Cycles: Integer);
    procedure Sample(out Left, Right: SmallInt);
    function IRQ: Boolean;
    function ReadBRAM(Offset: Word): Byte;
    procedure WriteBRAM(Offset: Word; Value: Byte);
    function SavePersistent: TBytes;
    procedure LoadPersistent(const Data: TBytes);
    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses
  System.Math;

function BCD(Value: Integer): Byte;
begin
  Value := EnsureRange(Value, 0, 99);
  Result := (Value div 10) * 16 + Value mod 10;
end;

function FromBCD(Value: Byte): Integer;
begin
  Result := (Value shr 4) * 10 + (Value and 15);
end;

constructor TPCECDROM.Create(Disc: TCDDisc; SuperCD: Boolean);
const
  Header: array[0..7] of Byte = ($48, $55, $42, $4D, 0, $A0, $10, $80);
begin
  inherited Create;
  FDisc := Disc;
  FSuper := SuperCD;
  Move(Header, FBRAM, SizeOf(Header));
  Reset;
end;

procedure TPCECDROM.Reset;
begin
  FState := Default(TPCECDState);
  FState.BRAMLocked := True;
  FState.ADSignal := 2048;
  FState.FadeCD := 1;
  FState.FadeAD := 1;
  FAudio := nil;
end;

function TPCECDROM.IRQ: Boolean;
begin
  Result := FState.IRQPending and FState.IRQEnable <> 0;
end;

procedure TPCECDROM.Status(Code: Byte);
begin
  FState.Phase := TPCESCSIPhase.Status;
  FState.StatusCode := Code;
  FState.Request := True;
  FState.IRQPending := (FState.IRQPending and $9F) or $20;
end;

procedure TPCECDROM.DataReady;
begin
  FState.Phase := TPCESCSIPhase.DataIn;
  FState.Request := True;
  FState.IRQPending := (FState.IRQPending and $9F) or $40;
end;

function TPCECDROM.DataByte: Byte;
begin
  case FState.Phase of
    TPCESCSIPhase.Status:
      Result := FState.StatusCode;
    TPCESCSIPhase.MessageIn:
      Result := 0;
    TPCESCSIPhase.DataIn:
      begin
        Result := 0;
        if FState.BufferPosition < FState.BufferSize then
          Result := FState.Buffer[FState.BufferPosition];
      end;
  else
    Result := FState.DataPort;
  end;
end;

procedure TPCECDROM.NextSector;
begin
  if (FDisc = nil) or not FDisc.IsData(FState.Sector) then
  begin
    Status(2);
    Exit;
  end;
  var Data: TBytes;
  FDisc.ReadData(FState.Sector, Data);
  if Length(Data) <> 2048 then
  begin
    Status(2);
    Exit;
  end;
  Move(Data[0], FState.Buffer, 2048);
  FState.BufferSize := 2048;
  FState.BufferPosition := 0;
  Inc(FState.Sector);
  Dec(FState.SectorsRemaining);
  DataReady;
end;

function TPCECDROM.AudioAddress: Integer;
begin
  case FState.Command[9] and $C0 of
    0:
      Result := (Integer(FState.Command[3]) shl 16) or (Integer(FState.Command[4]) shl 8) or FState.Command[5];
    $40:
      Result := (FromBCD(FState.Command[2]) * 60 + FromBCD(FState.Command[3])) * 75 + FromBCD(FState.Command[4]) - 150;
    $80:
      begin
        var T := FromBCD(FState.Command[2]);
        if (FDisc = nil) or (T < 1) or (T > FDisc.TrackCount) then
          Exit(-1);
        Result := FDisc.Track(T).StartLBA;
      end;
  else
    Result := -1;
  end;
end;

procedure TPCECDROM.Command;

  procedure Position(Value, Offset: Integer);
  begin
    Value := Max(0, Value);
    FState.Buffer[Offset] := BCD(Value div 4500);
    FState.Buffer[Offset + 1] := BCD(Value div 75 mod 60);
    FState.Buffer[Offset + 2] := BCD(Value mod 75);
  end;

begin
  FState.CommandCount := 0;
  FState.BufferPosition := 0;
  FState.BufferSize := 0;
  if FDisc = nil then
  begin
    Status(2);
    Exit;
  end;
  case FState.Command[0] of
    $00:
      Status;
    $08:
      begin
        FState.AudioPlaying := False;
        FState.Sector := (Integer(FState.Command[1] and $1F) shl 16) or
          (Integer(FState.Command[2]) shl 8) or FState.Command[3];
        FState.SectorsRemaining := FState.Command[4];
        if FState.SectorsRemaining = 0 then
          FState.SectorsRemaining := 256;
        FState.Phase := TPCESCSIPhase.Waiting;
        FState.Request := False;
        FState.Delay := 7160;
      end;
    $D8:
      begin
        var A := AudioAddress;
        if (A < 0) or (A >= FDisc.LeadOut) then
        begin
          Status(2);
          Exit;
        end;
        FState.AudioStart := A;
        FState.AudioSector := A;
        FState.AudioPosition := 0;
        FState.AudioEnd := FDisc.LeadOut;
        FState.AudioPlaying := True;
        FState.AudioPaused := FState.Command[1] = 0;
        FState.AudioMode := 3;
        FAudio := nil;
        Status;
      end;
    $D9:
      begin
        var A := AudioAddress;
        if (A < FState.AudioStart) or (A > FDisc.LeadOut) then
        begin
          Status(2);
          Exit;
        end;
        FState.AudioEnd := A;
        FState.AudioMode := FState.Command[1];
        if FState.AudioMode = 0 then
          FState.AudioPlaying := False;
        if FState.AudioMode in [1, 2] then
          FState.AudioPaused := False;
        Status;
      end;
    $DA:
      begin
        FState.AudioPaused := True;
        Status;
      end;
    $DD:
      begin
        FillChar(FState.Buffer, 10, 0);
        FState.BufferSize := 10;
        if not FState.AudioPlaying then
          FState.Buffer[0] := 3
        else
          FState.Buffer[0] := Ord(FState.AudioPaused) * 2;
        var Sector := FState.Sector;
        if FState.AudioPlaying then
          Sector := FState.AudioSector;
        var TrackNo := FDisc.TrackAt(Sector) + 1;
        FState.Buffer[1] := 1 or (Ord(FDisc.IsData(Sector)) * $40);
        FState.Buffer[2] := BCD(TrackNo);
        FState.Buffer[3] := 1;
        if TrackNo > 0 then
          Position(Sector - FDisc.Track(TrackNo).StartLBA, 4);
        Position(Sector + 150, 7);
        DataReady;
      end;
    $DE:
      begin
        FillChar(FState.Buffer, 4, 0);
        FState.BufferSize := 4;
        case FState.Command[1] of
          0:
            begin
              FState.Buffer[0] := 1;
              FState.Buffer[1] := BCD(FDisc.TrackCount);
            end;
          1:
            Position(FDisc.LeadOut + 150, 0);
          2:
            begin
              var T := FromBCD(FState.Command[2]);
              if T = 0 then
                T := 1;
              if T > FDisc.TrackCount then
                Position(FDisc.LeadOut + 150, 0)
              else
              begin
                var Track := FDisc.Track(T);
                Position(Track.StartLBA + 150, 0);
                FState.Buffer[3] := Ord(not Track.Audio) * 4;
              end;
            end;
        else
          begin
            Status(2);
            Exit;
          end;
        end;
        DataReady;
      end;
  else
    Status(2);
  end;
end;

procedure TPCECDROM.Acknowledge;
begin
  if not FState.Request then
    Exit;
  FState.Request := False;
  case FState.Phase of
    TPCESCSIPhase.Command:
      begin
        if FState.CommandCount < 10 then
        begin
          FState.Command[FState.CommandCount] := FState.DataPort;
          Inc(FState.CommandCount);
        end;
        var Count := 10;
        if FState.Command[0] in [0, $08] then
          Count := 6;
        if FState.CommandCount >= Count then
          Command;
      end;
    TPCESCSIPhase.DataIn:
      begin
        Inc(FState.BufferPosition);
        if FState.BufferPosition >= FState.BufferSize then
        begin
          FState.IRQPending := FState.IRQPending and $BF;
          if FState.SectorsRemaining > 0 then
          begin
            FState.Phase := TPCESCSIPhase.Waiting;
            FState.Delay := 7160000 div 75;
          end
          else
            Status;
        end;
      end;
    TPCESCSIPhase.Status:
      begin
        FState.IRQPending := FState.IRQPending and $DF;
        FState.Phase := TPCESCSIPhase.MessageIn;
      end;
    TPCESCSIPhase.MessageIn:
      FState.Phase := TPCESCSIPhase.Idle;
  end;
end;

function TPCECDROM.Read(Address: Word): Byte;
const
  Signature: array[0..3] of Byte = (0, $AA, $55, 3);
begin
  Address := Address and $3FF;
  Result := $FF;
  case Address of
    0:
      begin
        case FState.Phase of
          TPCESCSIPhase.Command:
            Result := $90;
          TPCESCSIPhase.DataIn:
            Result := $88;
          TPCESCSIPhase.Status:
            Result := $98;
          TPCESCSIPhase.MessageIn:
            Result := $B8;
          TPCESCSIPhase.Waiting:
            Result := $80;
        else
          Result := 0;
        end;
        if FState.Request and not FState.ACK then
          Result := Result or $40;
      end;
    1:
      Result := DataByte;
    2:
      Result := FState.IRQEnable or (Ord(FState.ACK) * $80);
    3:
      begin
        Result := FState.IRQPending or (Ord(not FState.ReadRight) * 2);
        FState.BRAMLocked := True;
      end;
    4:
      Result := FState.ResetPort;
    5:
      Result := Word(FState.AudioLatch) and 255;
    6:
      Result := Word(FState.AudioLatch) shr 8;
    7:
      Result := 0;
    8:
      begin
        Result := DataByte;
        if FState.Phase = TPCESCSIPhase.DataIn then
        begin
          Acknowledge;
          if FState.Phase in [TPCESCSIPhase.DataIn, TPCESCSIPhase.Status, TPCESCSIPhase.MessageIn] then
            FState.Request := True;
        end;
      end;
    $A:
      begin
        Result := FState.ADReadBuffer;
        FState.ADReadBuffer := FADRAM[FState.ADRead];
        FState.ADRead := (FState.ADRead + 1) and $FFFF;
      end;
    $B:
      Result := FState.ADDMA;
    $C:
      Result := Ord(FState.ADLength = 0) or (Ord(FState.ADControl and $20 <> 0) * 8);
    $D:
      Result := FState.ADControl;
    $E:
      Result := FState.ADRate;
    $F:
      Result := FState.FadeControl;
    $C0..$C3:
      if FSuper then
        Result := Signature[Address and 3];
  end;
end;

procedure TPCECDROM.ADWrite(Value: Byte);
begin
  FADRAM[FState.ADWrite] := Value;
  FState.ADWrite := (FState.ADWrite + 1) and $FFFF;
  if FState.ADControl and $10 = 0 then
    FState.ADLength := (FState.ADLength + 1) and $1FFFF;
end;

procedure TPCECDROM.Write(Address: Word; Value: Byte);
begin
  case Address and $3FF of
    0:
      begin
        FState.Phase := TPCESCSIPhase.Command;
        FState.CommandCount := 0;
        FState.SectorsRemaining := 0;
        FState.Request := True;
        FState.IRQPending := FState.IRQPending and $9F;
      end;
    1:
      FState.DataPort := Value;
    2:
      begin
        FState.IRQEnable := Value and $7F;
        var ACK := Value and $80 <> 0;
        if ACK and not FState.ACK then
          Acknowledge;
        if not ACK and FState.ACK and
          (FState.Phase in [TPCESCSIPhase.Command, TPCESCSIPhase.DataIn, TPCESCSIPhase.Status, TPCESCSIPhase.MessageIn]) then
          FState.Request := True;
        FState.ACK := ACK;
      end;
    4:
      begin
        FState.ResetPort := Value and 15;
        if Value and 2 <> 0 then
        begin
          FState.Phase := TPCESCSIPhase.Idle;
          FState.Request := False;
          FState.IRQPending := 0;
          FState.IRQEnable := 0;
          FState.AudioPlaying := False;
        end;
      end;
    5:
      FState.ReadRight := not FState.ReadRight;
    7:
      FState.BRAMLocked := Value and $80 = 0;
    8:
      FState.ADAddress := (FState.ADAddress and $FF00) or Value;
    9:
      FState.ADAddress := (FState.ADAddress and 255) or (Integer(Value) shl 8);
    $A:
      ADWrite(Value);
    $B:
      FState.ADDMA := Value;
    $D:
      begin
        if (Value and 2 <> 0) and (FState.ADControl and 2 = 0) then
          FState.ADWrite := (FState.ADAddress - Ord(Value and 1 = 0)) and $FFFF;
        if (Value and 8 <> 0) and (FState.ADControl and 8 = 0) then
        begin
          FState.ADRead := (FState.ADAddress - Ord(Value and 4 = 0)) and $FFFF;
          FState.ADNibble := False;
        end;
        if Value and $10 <> 0 then
          FState.ADLength := FState.ADAddress;
        if Value and $80 <> 0 then
        begin
          FState.ADRead := 0;
          FState.ADWrite := 0;
          FState.ADLength := 0;
          FState.ADSignal := 2048;
          FState.ADStep := 0;
          FState.ADNibble := False;
        end;
        if (Value and $20 <> 0) and (FState.ADControl and $20 = 0) then
        begin
          FState.ADSignal := 2048;
          FState.ADStep := 0;
          FState.IRQPending := FState.IRQPending and $F3;
        end;
        FState.ADControl := Value;
      end;
    $E:
      FState.ADRate := Value and 15;
    $F:
      begin
        FState.FadeControl := Value;
        FState.FadeCD := 1;
        FState.FadeAD := 1;
        FState.FadeRateCD := 0;
        FState.FadeRateAD := 0;
        if Value in [8, 12] then
          FState.FadeRateCD := 1 / (44100 * IfThen(Value = 8, 6.0, 2.5));
        if Value = 10 then
          FState.FadeRateAD := 1 / (44100 * 6.0);
      end;
  end;
end;

procedure TPCECDROM.Advance(Cycles: Integer);
begin
  if FState.Phase = TPCESCSIPhase.Waiting then
  begin
    Dec(FState.Delay, Cycles);
    if FState.Delay <= 0 then
      NextSector;
  end;
  if FState.ADDMA and 3 <> 0 then
  begin
    Inc(FState.ADDMACycles, Cycles);
    while (FState.ADDMACycles >= 20) and (FState.Phase = TPCESCSIPhase.DataIn) do
    begin
      Dec(FState.ADDMACycles, 20);
      ADWrite(Read(8));
    end;
    if FState.Phase <> TPCESCSIPhase.DataIn then
      FState.ADDMA := FState.ADDMA and $FE;
  end;
end;

procedure TPCECDROM.Sample(out Left, Right: SmallInt);
const
  Steps: array[0..48] of Integer = (16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
    50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279,
    307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552);
  Adjust: array[0..7] of Integer = (-1, -1, -1, -1, 2, 4, 6, 8);
begin
  var L := 0;
  var R := 0;
  if FState.AudioPlaying and not FState.AudioPaused and (FDisc <> nil) then
  begin
    if FState.AudioSector >= FState.AudioEnd then
    begin
      if FState.AudioMode = 1 then
      begin
        FState.AudioSector := FState.AudioStart;
        FState.AudioPosition := 0;
        FAudio := nil;
      end
      else
      begin
        FState.AudioPlaying := False;
        if FState.AudioMode = 2 then
          Status;
      end;
    end;
    if FState.AudioPlaying then
    begin
      if Length(FAudio) = 0 then
        FDisc.ReadAudio(FState.AudioSector, FAudio);
      if Length(FAudio) = 2352 then
      begin
        var P := FState.AudioPosition * 4;
        L := Integer(FAudio[P]) or (Integer(FAudio[P + 1]) shl 8);
        R := Integer(FAudio[P + 2]) or (Integer(FAudio[P + 3]) shl 8);
        if L >= $8000 then
          Dec(L, $10000);
        if R >= $8000 then
          Dec(R, $10000);
        FState.AudioLatch := IfThen(FState.ReadRight, R, L);
      end;
      Inc(FState.AudioPosition);
      if FState.AudioPosition = 588 then
      begin
        FState.AudioPosition := 0;
        Inc(FState.AudioSector);
        FAudio := nil;
      end;
    end;
  end;
  var AD := 0;
  if FState.ADControl and $20 <> 0 then
  begin
    FState.ADPhase := FState.ADPhase + 32000.0 / ((16 - FState.ADRate) * 44100);
    while FState.ADPhase >= 1 do
    begin
      FState.ADPhase := FState.ADPhase - 1;
      var N := FADRAM[FState.ADRead];
      if not FState.ADNibble then
        N := N shr 4
      else
        N := N and 15;
      var Step := Steps[FState.ADStep];
      var Delta := Step div 8;
      if N and 1 <> 0 then
        Inc(Delta, Step div 4);
      if N and 2 <> 0 then
        Inc(Delta, Step div 2);
      if N and 4 <> 0 then
        Inc(Delta, Step);
      if N and 8 <> 0 then
        Delta := -Delta;
      FState.ADSignal := (FState.ADSignal + Delta) and $FFF;
      FState.ADStep := EnsureRange(FState.ADStep + Adjust[N and 7], 0, 48);
      if FState.ADNibble then
      begin
        FState.ADRead := (FState.ADRead + 1) and $FFFF;
        FState.ADLength := (FState.ADLength - 1) and $1FFFF;
        if FState.ADLength <= $8000 then
          FState.IRQPending := FState.IRQPending or 4;
        if FState.ADLength = 0 then
        begin
          FState.IRQPending := FState.IRQPending or 8;
          if FState.ADControl and $40 <> 0 then
            FState.ADControl := FState.ADControl and $DF;
        end;
      end;
      FState.ADNibble := not FState.ADNibble;
    end;
    AD := (FState.ADSignal - 2048) * 10;
  end;
  FState.FadeCD := Max(0, FState.FadeCD - FState.FadeRateCD);
  FState.FadeAD := Max(0, FState.FadeAD - FState.FadeRateAD);
  Left := EnsureRange(Round(L * FState.FadeCD + AD * FState.FadeAD), -32768, 32767);
  Right := EnsureRange(Round(R * FState.FadeCD + AD * FState.FadeAD), -32768, 32767);
end;

function TPCECDROM.ReadBRAM(Offset: Word): Byte;
begin
  Result := $FF;
  if not FState.BRAMLocked and (Offset < $800) then
    Result := FBRAM[Offset];
end;

procedure TPCECDROM.WriteBRAM(Offset: Word; Value: Byte);
begin
  if not FState.BRAMLocked and (Offset < $800) then
    FBRAM[Offset] := Value;
end;

function TPCECDROM.SavePersistent: TBytes;
begin
  SetLength(Result, SizeOf(FBRAM));
  Move(FBRAM, Result[0], Length(Result));
end;

procedure TPCECDROM.LoadPersistent(const Data: TBytes);
begin
  if Length(Data) = 0 then
    Exit;
  if Length(Data) <> SizeOf(FBRAM) then
    raise EReadError.Create('Invalid PC Engine BRAM save size');
  Move(Data[0], FBRAM, Length(Data));
end;

procedure TPCECDROM.SerializeState(State: TStateArchive);
begin
  State.Field(FState, SizeOf(FState));
  State.Field(FBRAM, SizeOf(FBRAM));
  State.Field(FADRAM, SizeOf(FADRAM));
  if State.Loading then
  begin
    FAudio := nil;
    if (FState.CommandCount < 0) or (FState.CommandCount > 10) or
      (FState.BufferSize < 0) or (FState.BufferSize > 2048) or
      (FState.BufferPosition < 0) or (FState.BufferPosition > FState.BufferSize) or
      (FState.ADRead < 0) or (FState.ADRead > $FFFF) or
      (FState.ADWrite < 0) or (FState.ADWrite > $FFFF) or
      (FState.ADStep < 0) or (FState.ADStep > 48) or
      (FState.AudioPosition < 0) or (FState.AudioPosition >= 588) then
      raise EReadError.Create('Invalid PC Engine CD state');
  end;
end;

end.

