unit ZX.DMAUSC;

interface

uses
  System.SysUtils, Core.Snapshots, ZX.PIT8253;

type
  TZXUSCRead = function(Context: Pointer; Address: Cardinal): Byte;

  TZXUSCWrite = procedure(Context: Pointer; Address: Cardinal; Value: Byte);

  TZXUSCChannel = record
    BaseAddress, Address, BaseCount, Count: Word;
    Mode, Bank: Byte;
  end;

  // Witchcraft/Stranger DMA USC: native 8237A, two readable 8253s, 4 DACs.
  // The board owns no ROM or sample RAM. Callbacks address motherboard RAM.
  TZXDMAUSC = class
  private
    FChannels: array[0..3] of TZXUSCChannel;
    FSample, FVolume: array[0..3] of Byte;
    FTimers: array[0..1] of TZX8253;
    FCommand, FStatus, FMask, FRequest, FDREQ, FTemp, FData, FPriority: Byte;
    FHigh, FHalfClock, FULABypass: Boolean;
    FIRQControl, FPending: Byte; // pending: EOP, timer 2, timer 1
    FActive, FCycles: Integer;
    FMemoryTransfer, FReleased: Boolean;
    FTransfers, FBusClocks: UInt64;
    FContext: Pointer;
    FRead: TZXUSCRead;
    FWrite: TZXUSCWrite;
    procedure ResetDMA;
    function Requests: Byte;
    function SelectChannel: Integer;
    function PhysicalAddress(Channel: Integer): Cardinal;
    procedure EndTransfer;
    procedure Terminal(Channel: Integer);
    procedure ChangeAddress(Channel: Integer);
    procedure WriteDMA(RegisterIndex: Byte; Value: Byte);
    function ReadDMA(RegisterIndex: Byte): Byte;
  public
    constructor Create(Context: Pointer; ReadRAM: TZXUSCRead; WriteRAM: TZXUSCWrite);
    destructor Destroy; override;
    procedure Reset;
    procedure ConfigureULABypass(PassULA: Boolean);
    function ReadPort(Address: Word; out Value: Byte): Boolean;
    function WritePort(Address: Word; Value: Byte): Boolean;
    procedure Tick(BusGranted: Boolean);
    function BusRequest: Boolean;
    function BeginBus: Boolean;
    function Interrupt(ULA: Boolean): Boolean;
    function InterruptVector(ULA: Boolean): Byte;
    procedure Acknowledge;
    procedure Levels(Stereo: Integer; out Left, Right: Double);
    procedure SerializeState(State: TStateArchive);
    property Released: Boolean read FReleased;
    property Transfers: UInt64 read FTransfers;
    property BusClocks: UInt64 read FBusClocks;
  end;

implementation

uses
  System.Classes;

constructor TZXDMAUSC.Create(Context: Pointer; ReadRAM: TZXUSCRead; WriteRAM: TZXUSCWrite);
begin
  inherited Create;
  FContext := Context;
  FRead := ReadRAM;
  FWrite := WriteRAM;
  FTimers[0] := TZX8253.Create;
  FTimers[1] := TZX8253.Create;
  Reset;
end;

destructor TZXDMAUSC.Destroy;
begin
  FTimers[1].Free;
  FTimers[0].Free;
  inherited;
end;

procedure TZXDMAUSC.ResetDMA;
begin
  FCommand := 0;
  FStatus := 0;
  FMask := 15;
  FRequest := 0;
  FTemp := 0;
  FData := 0;
  FHigh := False;
  FPriority := 0;
  FActive := -1;
  FCycles := 0;
  FMemoryTransfer := False;
  FReleased := False;
end;

procedure TZXDMAUSC.Reset;
begin
  FillChar(FChannels, SizeOf(FChannels), 0);
  FillChar(FSample, SizeOf(FSample), $80);
  FillChar(FVolume, SizeOf(FVolume), 0);
  ResetDMA;
  FULABypass := False;
  FDREQ := 0;
  FHalfClock := False;
  FPending := 0;
  FIRQControl := 0;
  FTimers[0].Reset;
  FTimers[1].Reset;
  FTransfers := 0;
  FBusClocks := 0;
end;

procedure TZXDMAUSC.ConfigureULABypass(PassULA: Boolean);
begin
  // Early players write zero to the IRQ latch and still require frame INT.
  // This explicit compatibility option models the uncut motherboard INT path.
  // Disable it for the complete DD18/DD19 controller shown in the schematic.
  FULABypass := PassULA;
end;

function TZXDMAUSC.Requests: Byte;
begin
  Result := FDREQ;
  if (FCommand and $40) <> 0 then
    Result := Result xor 15;
  for var I := 0 to 3 do
    if (FChannels[I].Mode and $C0) = $80 then
      Result := Result or (FRequest and (1 shl I));
end;

function TZXDMAUSC.SelectChannel: Integer;
begin
  Result := -1;
  if (FCommand and 4) <> 0 then
    Exit;
  var Request := Requests and not FMask;
  // Intel 8237A: software requests are non-maskable, and block-mode only.
  for var I := 0 to 3 do
    if (FChannels[I].Mode and $C0) = $80 then
      Request := Request or (FRequest and (1 shl I));
  if (FCommand and 1) <> 0 then
  begin
    if (Request and 1) <> 0 then
      Result := 0;
    Exit;
  end;
  for var I := 0 to 3 do
  begin
    var Channel := (FPriority + I) and 3;
    if ((Request and (1 shl Channel)) <> 0) and ((FChannels[Channel].Mode and $C0) <> $C0) then
      Exit(Channel);
  end;
end;

function TZXDMAUSC.BusRequest: Boolean;
begin
  Result := (FActive >= 0) or (SelectChannel >= 0);
end;

function TZXDMAUSC.PhysicalAddress(Channel: Integer): Cardinal;
begin
  Result := (Cardinal(FChannels[Channel].Bank) shl 16) or FChannels[Channel].Address;
end;

function TZXDMAUSC.BeginBus: Boolean;
begin
  FReleased := False;
  if FActive < 0 then
  begin
    FActive := SelectChannel;
    if FActive < 0 then
      Exit(False);
    FMemoryTransfer := (FCommand and 1) <> 0;
    FCycles := 4;
    if FMemoryTransfer then
      FCycles := 8
    else if (FCommand and 8) <> 0 then
      FCycles := 3;
    // Memory-to-memory never asserts DACK, so it must not clear audio requests.
    if not FMemoryTransfer then
      FDREQ := FDREQ and not (1 shl FActive);
  end;
  Result := True;
end;

procedure TZXDMAUSC.ChangeAddress(Channel: Integer);
begin
  if (FChannels[Channel].Mode and $20) <> 0 then
    FChannels[Channel].Address := (Cardinal(FChannels[Channel].Address) + $FFFF) and $FFFF
  else
    FChannels[Channel].Address := (Cardinal(FChannels[Channel].Address) + 1) and $FFFF;
end;

procedure TZXDMAUSC.Terminal(Channel: Integer);
begin
  FStatus := FStatus or (1 shl Channel);
  FRequest := FRequest and not (1 shl Channel);
  if (FChannels[Channel].Mode and $10) <> 0 then
  begin
    FChannels[Channel].Address := FChannels[Channel].BaseAddress;
    FChannels[Channel].Count := FChannels[Channel].BaseCount;
  end
  else
    FMask := FMask or (1 shl Channel);
  if (FIRQControl and 1) = 0 then
    FPending := FPending or 1;
end;

procedure TZXDMAUSC.EndTransfer;
begin
  Inc(FTransfers);
  var Channel := FActive;
  var OldHigh := FChannels[Channel].Address shr 8;
  if FMemoryTransfer then
  begin
    if (FCommand and 2) = 0 then
      ChangeAddress(0);
    ChangeAddress(1);
    Channel := 1;
  end
  else
    ChangeAddress(Channel);
  var TC := FChannels[Channel].Count = 0;
  FChannels[Channel].Count := (Cardinal(FChannels[Channel].Count) + $FFFF) and $FFFF;
  if TC then
  begin
    Terminal(Channel);
    if FMemoryTransfer then
    begin
      Terminal(0);
    end;
  end;
  var Mode := FChannels[FActive].Mode and $C0;
  var Hold := not TC and ((Mode = $80) or ((Mode = 0) and ((Requests and (1 shl FActive)) <> 0)));
  if Hold then
  begin
    // S1 is needed again only when the multiplexed high address changes.
    FCycles := 3 + Ord((FChannels[FActive].Address shr 8) <> OldHigh);
    if FMemoryTransfer then
      FCycles := 8
    else if (FCommand and 8) <> 0 then
      Dec(FCycles);
  end
  else
  begin
    if (FCommand and $10) <> 0 then
      FPriority := (FActive + 1) and 3;
    FActive := -1;
    FReleased := True;
  end;
end;

procedure TZXDMAUSC.Tick(BusGranted: Boolean);
begin
  FHalfClock := not FHalfClock;
  for var T := 0 to 1 do
  begin
    for var C := 0 to 1 do
    begin
      FTimers[T].Tick(C);
      var Channel := T * 2 + C;
      if not FTimers[T].Output(C) and ((FActive <> Channel) or FMemoryTransfer) then
        FDREQ := FDREQ or (1 shl Channel);
    end;
    if FHalfClock then
    begin
      var Old := FTimers[T].Output(2);
      FTimers[T].Tick(2);
      if Old and not FTimers[T].Output(2) and ((FIRQControl and (2 shl T)) <> 0) then
        FPending := FPending or (4 shr T);
    end;
  end;
  if not BusGranted or (FActive < 0) then
    Exit;
  Inc(FBusClocks);
  Dec(FCycles);
  if FMemoryTransfer then
  begin
    if FCycles = 5 then
      FTemp := FRead(FContext, PhysicalAddress(0));
    if FCycles = 1 then
      FWrite(FContext, PhysicalAddress(1), FTemp);
  end
  else
    case FChannels[FActive].Mode and 12 of
      8:
        begin
          if FCycles = 2 - Ord((FCommand and 8) <> 0) then
            FData := FRead(FContext, PhysicalAddress(FActive));
          if FCycles = 1 then
            FSample[FActive] := FData;
        end;
      4:
        if FCycles = 1 then
          FWrite(FContext, PhysicalAddress(FActive), $FF); // no external input peripheral
    end;
  if FCycles = 0 then
    EndTransfer;
end;

procedure TZXDMAUSC.WriteDMA(RegisterIndex: Byte; Value: Byte);
begin
  if RegisterIndex < 8 then
  begin
    var Channel := RegisterIndex shr 1;
    var N: Word;
    if (RegisterIndex and 1) = 0 then
      N := FChannels[Channel].BaseAddress
    else
      N := FChannels[Channel].BaseCount;
    if FHigh then
      N := (N and $FF) or (Word(Value) shl 8)
    else
      N := (N and $FF00) or Value;
    if (RegisterIndex and 1) = 0 then
    begin
      FChannels[Channel].BaseAddress := N;
      FChannels[Channel].Address := N;
    end
    else
    begin
      FChannels[Channel].BaseCount := N;
      FChannels[Channel].Count := N;
    end;
    FHigh := not FHigh;
    Exit;
  end;
  var Channel := Value and 3;
  case RegisterIndex of
    8:
      FCommand := Value;
    9:
      if (Value and 4) <> 0 then
        FRequest := FRequest or (1 shl Channel)
      else
        FRequest := FRequest and not (1 shl Channel);
    10:
      if (Value and 4) <> 0 then
        FMask := FMask or (1 shl Channel)
      else
        FMask := FMask and not (1 shl Channel);
    11:
      FChannels[Channel].Mode := Value and $FC;
    12:
      FHigh := False;
    13:
      ResetDMA;
    14:
      FMask := 0;
    15:
      FMask := Value and 15;
  end;
end;

function TZXDMAUSC.ReadDMA(RegisterIndex: Byte): Byte;
begin
  Result := $FF;
  if RegisterIndex < 8 then
  begin
    var N: Word;
    if (RegisterIndex and 1) = 0 then
      N := FChannels[RegisterIndex shr 1].Address
    else
      N := FChannels[RegisterIndex shr 1].Count;
    if FHigh then
      Result := N shr 8
    else
      Result := N and 255;
    FHigh := not FHigh;
  end
  else
    case RegisterIndex of
      8:
        begin
          Result := FStatus or (Requests shl 4);
          FStatus := 0;
        end;
      13, 15:
        Result := FTemp;
    end;
end;

function TZXDMAUSC.WritePort(Address: Word; Value: Byte): Boolean;
begin
  Result := False;
  // DD1 decodes A3..A9; A0..A2 and A10 are don't-care on the published board.
  if ((Address and $78) <> $70) or ((Address and $80) <> 0) then
    Exit;
  Result := True;
  case (Address shr 8) and 3 of
    0:
      WriteDMA(Address shr 12, Value);
    1, 2:
      FTimers[((Address shr 8) and 3) - 1].Write(Address shr 14, Value);
    3:
      begin
        if (Address and $800) <> 0 then
          FVolume[Address shr 14] := Value and 63
        else
          case Address shr 14 of
            0:
              FChannels[(Address shr 12) and 3].Bank := Value and 15;
            3:
              FIRQControl := Value and 15;
          end;
      end;
  end;
end;

function TZXDMAUSC.ReadPort(Address: Word; out Value: Byte): Boolean;
begin
  Result := False;
  Value := $FF;
  if ((Address and $78) <> $70) or ((Address and $80) <> 0) then
    Exit;
  case (Address shr 8) and 3 of
    0:
      begin
        Value := ReadDMA(Address shr 12);
        Result := True;
      end;
    1, 2:
      begin
        Value := FTimers[((Address shr 8) and 3) - 1].Read(Address shr 14);
        Result := True;
      end;
    // Bank, IRQ and volume latches have no read bus.
  end;
end;

function TZXDMAUSC.Interrupt(ULA: Boolean): Boolean;
begin
  Result := (FPending <> 0) or (ULA and (((FIRQControl and 8) <> 0) or FULABypass));
end;

function TZXDMAUSC.InterruptVector(ULA: Boolean): Byte;
begin
  // DD17: bits 0..3 tied high, EOP/T2/T1 are active-low, D7 is ULA presence.
  Result := $7F or (Ord(ULA and (((FIRQControl and 8) <> 0) or FULABypass)) shl 7);
  Result := Result and not (FPending shl 4);
end;

procedure TZXDMAUSC.Acknowledge;
begin
  FPending := 0;
end;

procedure TZXDMAUSC.Levels(Stereo: Integer; out Left, Right: Double);
var
  S: array[0..3] of Integer;
begin
  for var I := 0 to 3 do
    S[I] := (Integer(FSample[I]) - 128) * FVolume[I];
  case Stereo of
    1:
      begin
        Left := S[0] + S[1];
        Right := S[2] + S[3];
      end;
    2:
      begin
        Left := (S[0] + S[1] + S[2] + S[3]) * 0.5;
        Right := Left;
      end;
  else
    Left := S[0] + S[3];
    Right := S[1] + S[2];
  end;
  Left := Left / (128.0 * 63 * 2) * 0.25;
  Right := Right / (128.0 * 63 * 2) * 0.25;
end;

procedure TZXDMAUSC.SerializeState(State: TStateArchive);
begin
  State.Field(FChannels, SizeOf(FChannels));
  State.Field(FSample, SizeOf(FSample));
  State.Field(FVolume, SizeOf(FVolume));
  for var T in FTimers do
    T.SerializeState(State);
  State.Field(FCommand, 1);
  State.Field(FStatus, 1);
  State.Field(FMask, 1);
  State.Field(FRequest, 1);
  State.Field(FDREQ, 1);
  State.Field(FTemp, 1);
  State.Field(FData, 1);
  State.Field(FPriority, 1);
  State.Field(FULABypass, SizeOf(FULABypass));
  State.Field(FHigh, SizeOf(FHigh));
  State.Field(FHalfClock, SizeOf(FHalfClock));
  State.Field(FIRQControl, 1);
  State.Field(FPending, 1);
  State.Field(FActive, 4);
  State.Field(FCycles, 4);
  State.Field(FMemoryTransfer, SizeOf(FMemoryTransfer));
  State.Field(FReleased, SizeOf(FReleased));
  State.Field(FTransfers, 8);
  State.Field(FBusClocks, 8);
  if (FStatus > 15) or (FMask > 15) or (FRequest > 15) or (FDREQ > 15) or (FPriority > 3) or
    (FIRQControl > 15) or (FPending > 7) or (FActive < -1) or (FActive > 3) or (FCycles < 0) or (FCycles > 8) or
    ((FActive < 0) <> (FCycles = 0)) or ((FActive >= 0) and FMemoryTransfer and (FActive <> 0)) then
    raise EReadError.Create('Invalid DMA USC state');
  for var I := 0 to 3 do
    if (FChannels[I].Bank > 15) or ((FChannels[I].Mode and 3) <> 0) or (FVolume[I] > 63) then
      raise EReadError.Create('Invalid DMA USC channel');
end;

end.

