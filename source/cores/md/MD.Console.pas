unit MD.Console;

interface

uses
  System.SysUtils, System.UITypes, MD.Cartridge, MD.M68k, MD.Z80, MD.VDP,
  MD.Sound;

{$SCOPEDENUMS ON}

type
  TMDButton = (Up, Down, Left, Right, A, B, C, Start, X, Y, Z, Mode);

  TMDButtons = set of TMDButton;

  TMDConsole = class
  private
    FCartridge: TMDCartridge;
    FCPU: TM68kState;
    FCPUCallbacks: TM68kReadWriteCallbacks;
    FZ80: TZ80State;
    FZ80Callbacks: TZ80ReadAndWriteCallbacks;
    FVDP: TVDP;
    FFM: TFM;
    FPSG: TPSG;
    FRAM: array[0..65535] of Byte;
    FZRAM: array[0..8191] of Byte;
    FIO: array[0..15] of Byte;
    FPalette: array[0..191] of TAlphaColor;
    FFrame: TArray<TAlphaColor>;
    FAudio: TArray<SmallInt>;
    FAudioCount: Integer;
    FWidth, FHeight, FScanline, FMasterClock, FLines: Integer;
    FFrameNumber: UInt64;
    FFrameTime, FCPUTime, FCPUBase, FZ80Time, FBusTime: Int64;
    FAudioTime, FNextFM, FNextPSG, FNextPCM, FPCMNumber, FLastPCM: Int64;
    FAreaLeft, FAreaRight: Int64;
    FFMSamples: array[0..1] of SmallInt;
    FPSGSamples: array[0..0] of SmallInt;
    FBusyUntil, FPadTimeout: Int64;
    FBusRequested, FZReset, FInZ80, FVInt, FHInt: Boolean;
    FZBank: Word;
    FButtons: TMDButtons;
    FStrobes: Integer;
    FTH: Boolean;
    FSRAM: TBytes;
    FSRAMStart, FSRAMEnd, FSRAMStride: Cardinal;
    FSRAMEnabled, FSRAMReadOnly, FSRAMDirty: Boolean;
    FBanks: array[0..7] of Byte;
    FDMADebt: Int64;
    procedure SyncAudio(Target: Int64);
    procedure SyncZ80(Target: Int64);
    procedure RunUntil(Target: Int64);
    procedure UpdateIRQ;
    function ReadPad: Byte;
    procedure WriteIO(Index: Integer; Value: Byte);
    function ReadZ80(Address: Word): Byte;
    procedure WriteZ80(Address: Word; Value: Byte);
    function ReadBus(Address: Cardinal; HighByte, LowByte: Boolean): Word;
    procedure WriteBus(Address: Cardinal; Value: Word; HighByte, LowByte: Boolean);
    function SRAMIndex(Address: Cardinal; out Index: Cardinal): Boolean;
  public
    constructor Create(const Data: TBytes; const Extension: string);
    destructor Destroy; override;
    procedure Reset;
    procedure RunFrame;
    procedure SetInput(const Buttons: TMDButtons);
    function ReadByte(Address: Cardinal): Byte;
    function ReadWord(Address: Cardinal): Word;
    procedure WriteByte(Address: Cardinal; Value: Byte);
    procedure WriteWord(Address: Cardinal; Value: Word);
    procedure LoadBattery(const Data: TBytes);
    function BatteryData: TBytes;
    property BatteryDirty: Boolean read FSRAMDirty;
    property Pixels: TArray<TAlphaColor> read FFrame;
    property Samples: TArray<SmallInt> read FAudio;
    property SampleFrames: Integer read FAudioCount;
    property Width: Integer read FWidth;
    property Height: Integer read FHeight;
    property FrameNumber: UInt64 read FFrameNumber;
    function FramesPerSecond: Double;

  end;

implementation

uses
  System.Math;

function CPURead(User: Pointer; Address: Cardinal; Hi, Lo: Byte; Cycle: Cardinal; Early: PByte): Cardinal;
var
  C: TMDConsole;
begin
  C := TMDConsole(User);
  C.FBusTime := C.FCPUBase + Int64(Cycle) * 7;
  Result := C.ReadBus(Address * 2, Hi <> 0, Lo <> 0);
end;

procedure CPUWrite(User: Pointer; Address: Cardinal; Hi, Lo: Byte; Cycle: Cardinal; Early: PByte; Value: Cardinal);
var
  C: TMDConsole;
begin
  C := TMDConsole(User);
  C.FBusTime := C.FCPUBase + Int64(Cycle) * 7;
  C.WriteBus(Address * 2, Word(Value), Hi <> 0, Lo <> 0);
end;

procedure CPUAck(User: Pointer);
var
  C: TMDConsole;
begin
  C := TMDConsole(User);
  if C.FCPU.PendingInterrupt = 6 then
    C.FVInt := False
  else
    C.FHInt := False;
  C.UpdateIRQ;
end;

function ZRead(User: Pointer; Address: Cardinal): Cardinal;
begin
  Result := TMDConsole(User).ReadZ80(Word(Address and $FFFF));
end;

procedure ZWrite(User: Pointer; Address, Value: Cardinal);
begin
  TMDConsole(User).WriteZ80(Word(Address and $FFFF), Byte(Value and $FF));
end;

procedure ColourUpdated(User: Pointer; Index, Colour: Cardinal);
begin
  if Index < 192 then
    TMDConsole(User).FPalette[Index] := $FF000000 or
      ((Colour and $F) * 17 shl 16) or (((Colour shr 4) and $F) * 17 shl 8) or
      (((Colour shr 8) and $F) * 17);
end;

procedure ScanlineRendered(User: Pointer; Line: Cardinal; const Pixels: array of Byte; PixelOffset: Integer; Left, Right, Width, Height: Cardinal);
var
  C: TMDConsole;
  X: Integer;
begin
  C := TMDConsole(User);
  if (Width > 320) or (Height > 480) or (Line >= Height) or
    (Left > Right) or (Right > Width) then
    raise Exception.Create('Invalid Mega Drive video dimensions');
  C.FWidth := Width;
  C.FHeight := Height;
  // Window and scrolling planes can publish separate spans of the same line.
  // Pixels outside this span still contain intermediate priority metadata.
  // Fixed stride inside the core; the frontend receives tightly packed pixels.
  for X := Integer(Left) to Integer(Right) - 1 do
    C.FFrame[Integer(Line) * 320 + X] := C.FPalette[Pixels[PixelOffset + X]];
end;

function DMARead(User: Pointer; Address, Cycle: Cardinal): Cardinal;
begin
  Result := TMDConsole(User).ReadWord(Address);
end;

procedure DMABegin(User: Pointer; Reads, Cycle: Cardinal);
begin
  // Approximate bus stall. VDP transfer contents and 128 KiB wrapping are
  // handled by the port; exact active-display DMA slot timing is not modelled.
  Inc(TMDConsole(User).FDMADebt, Int64(Reads) * 7);
end;

procedure KDebug(User: Pointer; Text: PByte);
begin
end;

constructor TMDConsole.Create(const Data: TBytes; const Extension: string);
var
  StartAddress, EndAddress: Cardinal;
begin
  inherited Create;
  FCartridge := TMDCartridge.Create(Data, Extension);
  FCPUCallbacks.UserData := Self;
  FCPUCallbacks.ReadCallback := CPURead;
  FCPUCallbacks.WriteCallback := CPUWrite;
  FCPUCallbacks.InterruptAcknowledgeCallback := CPUAck;
  FZ80Callbacks.UserData := Self;
  FZ80Callbacks.ReadCallback := ZRead;
  FZ80Callbacks.WriteCallback := ZWrite;
  FMasterClock := 53693175;
  FLines := 262;
  if FCartridge.Region = TMDRegion.Europe then
  begin
    FMasterClock := 53203424;
    FLines := 313;
  end;
  SetLength(FFrame, 320 * 480);
  SetLength(FAudio, 2048 * 2);
  if FCartridge.ReadWord($1B0) = $5241 then
  begin
    StartAddress := (Cardinal(FCartridge.ReadWord($1B4)) shl 16) or FCartridge.ReadWord($1B6);
    EndAddress := (Cardinal(FCartridge.ReadWord($1B8)) shl 16) or FCartridge.ReadWord($1BA);
    if (StartAddress <= EndAddress) and (EndAddress < $400000) and
      (EndAddress - StartAddress < $20000) then
    begin
      FSRAMStart := StartAddress;
      FSRAMEnd := EndAddress;
      if (StartAddress and 1) = (EndAddress and 1) then
        FSRAMStride := 2
      else
        FSRAMStride := 1;
      SetLength(FSRAM, (EndAddress - StartAddress) div FSRAMStride + 1);
    end;
  end;
  Reset;
end;

destructor TMDConsole.Destroy;
begin
  FCartridge.Free;
  inherited;
end;

procedure TMDConsole.Reset;
var
  I: Integer;
begin
  FillChar(FRAM, SizeOf(FRAM), 0);
  FillChar(FZRAM, SizeOf(FZRAM), 0);
  FillChar(FIO, SizeOf(FIO), 0);
  FCPU := Default(TM68kState);
  FZ80 := Default(TZ80State);
  FVDP := Default(TVDP);
  FFM := Default(TFM);
  FPSG := Default(TPSG);
  c_VDP_Initialise(@FVDP);
  FM_Initialise(@FFM);
  PSG_Initialise(@FPSG);
  c_ClownZ80_State_Initialise(@FZ80);
  for I := 0 to High(FPalette) do
    FPalette[I] := $FF000000;
  for I := 0 to High(FFrame) do
    FFrame[I] := $FF000000;
  for I := 0 to High(FBanks) do
    FBanks[I] := I;
  FWidth := 256;
  FHeight := 224;
  FFrameTime := 0;
  FCPUTime := 0;
  FCPUBase := 0;
  FBusTime := 0;
  FZ80Time := 0;
  FAudioTime := 0;
  FNextFM := 1008;
  FNextPSG := 240;
  FPCMNumber := 1;
  FNextPCM := FMasterClock div 44100;
  FLastPCM := 0;
  FAreaLeft := 0;
  FAreaRight := 0;
  FFMSamples[0] := 0;
  FFMSamples[1] := 0;
  FPSGSamples[0] := 0;
  FAudioCount := 0;
  FFrameNumber := 0;
  FScanline := 0;
  FDMADebt := 0;
  FBusyUntil := 0;
  FPadTimeout := 0;
  FZReset := True;
  FBusRequested := False;
  FInZ80 := False;
  FVInt := False;
  FHInt := False;
  FZBank := 0;
  FTH := True;
  FStrobes := 0;
  FIO[1] := $7F;
  FIO[2] := $7F;
  FSRAMEnabled := (Length(FSRAM) <> 0) and (Length(FCartridge.Data) <= Integer(FSRAMStart));
  FSRAMReadOnly := False;
  Clown68000Reset(@FCPU, @FCPUCallbacks);
end;

procedure TMDConsole.UpdateIRQ;
begin
  if FVInt and (FVDP.c_state.c_v_int_enabled <> 0) then
    FCPU.PendingInterrupt := 6
  else if FHInt and (FVDP.c_state.c_h_int_enabled <> 0) then
    FCPU.PendingInterrupt := 4
  else
    FCPU.PendingInterrupt := 0;
end;

procedure TMDConsole.SetInput(const Buttons: TMDButtons);
begin
  FButtons := Buttons;
end;

function TMDConsole.ReadPad: Byte;

  function Released(Button: TMDButton; Bit: Integer): Byte;
  begin
    if Button in FButtons then
      Result := 0
    else
      Result := 1 shl Bit;
  end;

begin
  if FBusTime >= FPadTimeout then
    FStrobes := 0;
  if FTH then
  begin
    Result := $40 or Released(TMDButton.B, 4) or Released(TMDButton.C, 5);
    if FStrobes = 3 then
      Result := Result or Released(TMDButton.Z, 0) or Released(TMDButton.Y, 1) or
        Released(TMDButton.X, 2) or Released(TMDButton.Mode, 3)
    else
      Result := Result or Released(TMDButton.Up, 0) or Released(TMDButton.Down, 1) or
        Released(TMDButton.Left, 2) or Released(TMDButton.Right, 3);
  end
  else
  begin
    Result := Released(TMDButton.A, 4) or Released(TMDButton.Start, 5);
    if FStrobes = 3 then
      Result := Result or $F
    else if FStrobes <> 2 then
      Result := Result or Released(TMDButton.Up, 0) or Released(TMDButton.Down, 1);
  end;
  Result := (Result and not FIO[4]) or (FIO[1] and FIO[4]);
end;

procedure TMDConsole.WriteIO(Index: Integer; Value: Byte);
var
  NewTH: Boolean;
begin
  FIO[Index] := Value;
  if (Index = 1) or (Index = 4) then
  begin
    NewTH := (FIO[4] and $40 = 0) or (FIO[1] and $40 <> 0);
    if FBusTime >= FPadTimeout then
      FStrobes := 0;
    if NewTH and not FTH then
    begin
      FStrobes := (FStrobes + 1) and 3;
      FPadTimeout := FBusTime + FMasterClock * 3 div 2000;
    end;
    FTH := NewTH;
  end;
end;

function TMDConsole.SRAMIndex(Address: Cardinal; out Index: Cardinal): Boolean;
begin
  Result := FSRAMEnabled and (Length(FSRAM) <> 0) and (Address >= FSRAMStart) and
    (Address <= FSRAMEnd);
  if Result then
  begin
    Result := ((Address - FSRAMStart) mod FSRAMStride) = 0;
    Index := (Address - FSRAMStart) div FSRAMStride;
  end;
end;

function TMDConsole.ReadBus(Address: Cardinal; HighByte, LowByte: Boolean): Word;
var
  Index, A: Cardinal;
  V: Byte;
begin
  Address := Address and $FFFFFE;
  if Address < $400000 then
  begin
    A := Cardinal(FBanks[Address shr 19]) * $80000 + (Address and $7FFFF);
    Result := FCartridge.ReadWord(A);
    if SRAMIndex(Address, Index) then
      Result := (Result and $FF) or (Word(FSRAM[Index]) shl 8);
    if SRAMIndex(Address + 1, Index) then
      Result := (Result and $FF00) or FSRAM[Index];
  end
  else if Address >= $E00000 then
    Result := (Word(FRAM[Address and $FFFF]) shl 8) or FRAM[(Address + 1) and $FFFF]
  else if (Address >= $A00000) and (Address <= $A0FFFF) then
  begin
    SyncZ80(FBusTime);
    Result := $FFFF;
    if FBusRequested and not FZReset then
    begin
      // The 68000's word access uses one Z80 bus cycle, repeating the byte.
      if HighByte then
        V := ReadZ80(Word(Address and $7FFF))
      else
        V := ReadZ80(Word((Address + 1) and $7FFF));
      Result := Word(V) * $101;
    end;
  end
  else if (Address >= $A10000) and (Address <= $A1001E) then
  begin
    Index := (Address and $1F) shr 1;
    case Index of
      0:
        begin
          V := $A0;
          if FCartridge.Region = TMDRegion.Japan then
            V := $20;
          if FCartridge.Region = TMDRegion.Europe then
            V := $E0;
        end;
      1:
        V := ReadPad;
      2, 3:
        V := $7F;
    else
      V := FIO[Index];
    end;
    Result := Word(V) * $101;
  end
  else if Address = $A11100 then
    Result := Word(Ord(not FBusRequested or FZReset)) shl 8
  else if (Address and $E700E0) = $C00000 then
  begin
    case Address and $1E of
      0, 2:
        Result := c_VDP_ReadData(@FVDP);
      4, 6:
        begin
          Result := c_VDP_ReadControl(@FVDP);
          if FLines = 313 then
            Result := Result or 1;
          if (FBusTime mod 3420) >= 2680 then
            Result := Result or 4;
        end;
      8, 10, 12, 14:
        begin
          Index := FScanline;
          if (FLines = 262) and (Index > 234) then
            Dec(Index, 6);
          if (FLines = 313) and (Index > 258) then
            Dec(Index, 57);
          Result := Word((Index and $FF) shl 8) or Word((FBusTime mod 3420 * 256 div 3420) and $FF);
        end;
    else
      Result := $FFFF;
    end;
  end
  else
    Result := $FFFF;
end;

procedure TMDConsole.WriteBus(Address: Cardinal; Value: Word; HighByte, LowByte: Boolean);
var
  Index: Cardinal;
  V: Byte;
begin
  Address := Address and $FFFFFE;
  if Address < $400000 then
  begin
    if not FSRAMReadOnly then
    begin
      if HighByte and SRAMIndex(Address, Index) then
      begin
        FSRAM[Index] := Value shr 8;
        FSRAMDirty := True;
      end;
      if LowByte and SRAMIndex(Address + 1, Index) then
      begin
        FSRAM[Index] := Value and $FF;
        FSRAMDirty := True;
      end;
    end;
  end
  else if Address >= $E00000 then
  begin
    if HighByte then
      FRAM[Address and $FFFF] := Value shr 8;
    if LowByte then
      FRAM[(Address + 1) and $FFFF] := Value and $FF;
  end
  else if (Address >= $A00000) and (Address <= $A0FFFF) then
  begin
    SyncZ80(FBusTime);
    if FBusRequested and not FZReset then
    begin
      if HighByte then
        WriteZ80(Word(Address and $7FFF), Value shr 8)
      else if LowByte then
        WriteZ80(Word((Address + 1) and $7FFF), Value and $FF);
    end;
  end
  else if (Address >= $A10000) and (Address <= $A1001E) then
  begin
    if LowByte then
      WriteIO((Address and $1F) shr 1, Value and $FF);
  end
  else if Address = $A11100 then
  begin
    SyncZ80(FBusTime);
    if HighByte then
      FBusRequested := Value and $100 <> 0;
  end
  else if Address = $A11200 then
  begin
    SyncZ80(FBusTime);
    if HighByte then
    begin
      if FZReset and (Value and $100 <> 0) then
        c_ClownZ80_Reset(@FZ80);
      FZReset := Value and $100 = 0;
      if FZReset then
      begin
        SyncAudio(FBusTime);
        FM_Initialise(@FFM);
      end;
    end;
  end
  else if Address = $A130F0 then
  begin
    if LowByte then
    begin
      FSRAMEnabled := Value and 1 <> 0;
      FSRAMReadOnly := Value and 2 <> 0;
    end;
  end
  else if (Address >= $A130F2) and (Address <= $A130FE) then
  begin
    if LowByte then
      FBanks[(Address - $A130F0) shr 1] := Value and $3F;
  end
  else if (Address and $E700E0) = $C00000 then
  begin
    if not (HighByte and LowByte) then
    begin
      if HighByte then
        V := Value shr 8
      else
        V := Value and $FF;
      Value := Word(V) * $101;
    end;
    case Address and $1E of
      0, 2:
        c_VDP_WriteData(@FVDP, Value, ColourUpdated, Self);
      4, 6:
        begin
          c_VDP_WriteControl(@FVDP, Value, ColourUpdated, Self, DMABegin,
            DMARead, Self, KDebug, Self, 0);
          UpdateIRQ;
        end;
      16, 18, 20, 22:
        if LowByte then
        begin
          SyncAudio(FBusTime);
          PSG_DoCommand(@FPSG, Value and $FF);
        end;
      28:
        c_VDP_WriteDebugData(@FVDP, Value);
      30:
        c_VDP_WriteDebugControl(@FVDP, Value);
    end;
  end;
end;

function TMDConsole.ReadByte(Address: Cardinal): Byte;
var
  V: Word;
begin
  V := ReadBus(Address and $FFFFFE, not Odd(Address), Odd(Address));
  if Odd(Address) then
    Result := V and $FF
  else
    Result := V shr 8;
end;

function TMDConsole.ReadWord(Address: Cardinal): Word;
begin
  Result := ReadBus(Address, True, True);
end;

procedure TMDConsole.WriteByte(Address: Cardinal; Value: Byte);
begin
  if Odd(Address) then
    WriteBus(Address and $FFFFFE, Value, False, True)
  else
    WriteBus(Address, Word(Value) shl 8, True, False);
end;

procedure TMDConsole.WriteWord(Address: Cardinal; Value: Word);
begin
  WriteBus(Address, Value, True, True);
end;

function TMDConsole.ReadZ80(Address: Word): Byte;
begin
  if Address < $4000 then
    Result := FZRAM[Address and $1FFF]
  else if Address < $6000 then
  begin
    SyncAudio(FBusTime);
    Result := FFM.State.Status and $7F;
    if FBusTime < FBusyUntil then
      Result := Result or $80;
  end
  else if Address >= $8000 then
  begin
    if (FZBank and $1FE) = $140 then
      Result := $FF // Exclude the entire A00000-A0FFFF window.
    else
      Result := ReadByte(Cardinal(FZBank) * $8000 + (Address and $7FFF));
  end
  else if Address >= $7F00 then
    Result := ReadByte($C00000 + (Address and $1F))
  else
    Result := $FF;
end;

procedure TMDConsole.WriteZ80(Address: Word; Value: Byte);
begin
  if Address < $4000 then
    FZRAM[Address and $1FFF] := Value
  else if Address < $6000 then
  begin
    SyncAudio(FBusTime);
    if not Odd(Address) then
      FM_DoAddress(@FFM, (Address shr 1) and 1, Value)
    else
    begin
      FM_DoData(@FFM, Value);
      FBusyUntil := FBusTime + 32 * 7;
    end;
  end
  else if Address < $6100 then
    FZBank := (FZBank shr 1) or (Word(Value and 1) shl 8)
  else if Address >= $8000 then
  begin
    if (FZBank and $1FE) <> $140 then
      WriteByte(Cardinal(FZBank) * $8000 + (Address and $7FFF), Value);
  end
  else if Address >= $7F00 then
    WriteByte($C00000 + (Address and $1F), Value);
end;

procedure TMDConsole.SyncZ80(Target: Int64);
var
  SavedBus: Int64;
  Cycles: Cardinal;
begin
  if FInZ80 or (Target <= FZ80Time) then
    Exit;
  if FBusRequested or FZReset then
  begin
    FZ80Time := Target;
    Exit;
  end;
  FInZ80 := True;
  SavedBus := FBusTime;
  try
    while FZ80Time < Target do
    begin
      FBusTime := FZ80Time;
      Cycles := c_ClownZ80_DoInstruction(@FZ80, @FZ80Callbacks);
      Inc(FZ80Time, Max(1, Integer(Cycles)) * 15);
      if FBusRequested or FZReset then
      begin
        FZ80Time := Target;
        Break;
      end;
    end;
  finally
    FBusTime := SavedBus;
    FInZ80 := False;
  end;
end;

procedure TMDConsole.SyncAudio(Target: Int64);
var
  Next, Delta, Span: Int64;
begin
  while FAudioTime < Target do
  begin
    Next := Min(Target, Min(FNextPCM, Min(FNextFM, FNextPSG)));
    Delta := Next - FAudioTime;
    Inc(FAreaLeft, (Integer(FFMSamples[0]) + Integer(FPSGSamples[0])) * Delta);
    Inc(FAreaRight, (Integer(FFMSamples[1]) + Integer(FPSGSamples[0])) * Delta);
    FAudioTime := Next;
    if Next = FNextFM then
    begin
      FFMSamples[0] := 0;
      FFMSamples[1] := 0;
      FM_OutputSamples(@FFM, FFMSamples);
      Inc(FNextFM, 1008);
    end;
    if Next = FNextPSG then
    begin
      FPSGSamples[0] := 0;
      PSG_Update(@FPSG, FPSGSamples);
      Inc(FNextPSG, 240);
    end;
    if Next = FNextPCM then
    begin
      Span := Next - FLastPCM;
      if FAudioCount < Length(FAudio) div 2 then
      begin
        FAudio[FAudioCount * 2] := EnsureRange(FAreaLeft div Span, Int64(-32768), Int64(32767));
        FAudio[FAudioCount * 2 + 1] := EnsureRange(FAreaRight div Span, Int64(-32768), Int64(32767));
        Inc(FAudioCount);
      end;
      FAreaLeft := 0;
      FAreaRight := 0;
      FLastPCM := Next;
      Inc(FPCMNumber);
      FNextPCM := FPCMNumber * FMasterClock div 44100;
    end;
  end;
end;

procedure TMDConsole.RunUntil(Target: Int64);
var
  Stall, Cycles: Int64;
begin
  if FCPUTime < Target then
  begin
    Stall := Min(FDMADebt, Target - FCPUTime);
    Dec(FDMADebt, Stall);
    Inc(FCPUTime, Stall);
    if FCPUTime < Target then
    begin
      FCPUBase := FCPUTime;

      Cycles := Clown68000DoCycles(@FCPU, @FCPUCallbacks, (Target - FCPUTime + 6) div 7);
      Inc(FCPUTime, Cycles * 7);
    end;
  end;
  SyncZ80(Target);
  SyncAudio(Target);
end;

procedure TMDConsole.RunFrame;
var
  Line, Visible, HCounter: Integer;
  Target: Int64;
begin
  FAudioCount := 0;
  Visible := 224;
  if FVDP.c_state.c_v30_enabled <> 0 then
    Visible := 240;
  HCounter := FVDP.c_state.c_h_int_interval;
  for Line := 0 to FLines - 1 do
  begin
    FScanline := Line;
    if Line = 0 then
      FVDP.c_state.c_currently_in_vblank := 0;
    if Line = Visible then
    begin
      FVDP.c_state.c_currently_in_vblank := 1;
      FVInt := True;
      UpdateIRQ;
      c_ClownZ80_Interrupt(@FZ80, 1);
    end;
    if Line = Visible + 1 then
      c_ClownZ80_Interrupt(@FZ80, 0);
    if Line < Visible then
    begin
      c_VDP_BeginScanline(@FVDP);
      Target := FFrameTime + Int64(Line) * 3420 + 1710;
      RunUntil(Target);
      if FVDP.c_state.c_double_resolution_enabled <> 0 then
      begin
        c_VDP_EndScanline(@FVDP, Line * 2, ScanlineRendered, Self);
        c_VDP_EndScanline(@FVDP, Line * 2 + 1, ScanlineRendered, Self);
      end
      else
        c_VDP_EndScanline(@FVDP, Line, ScanlineRendered, Self);
      if HCounter = 0 then
      begin
        FHInt := True;
        UpdateIRQ;
        HCounter := FVDP.c_state.c_h_int_interval;
      end
      else
        Dec(HCounter);
    end;
    RunUntil(FFrameTime + Int64(Line + 1) * 3420);
  end;
  Inc(FFrameTime, Int64(FLines) * 3420);
  Inc(FFrameNumber);
end;

function TMDConsole.FramesPerSecond: Double;
begin
  Result := FMasterClock / (FLines * 3420);
end;

procedure TMDConsole.LoadBattery(const Data: TBytes);
begin
  if Length(Data) <> Length(FSRAM) then
    raise EMDCartridge.Create('Mega Drive SRAM file has an invalid size');
  FSRAM := Copy(Data);
  FSRAMDirty := False;
end;

function TMDConsole.BatteryData: TBytes;
begin
  Result := Copy(FSRAM);
end;

initialization
  c_VDP_Constant_Initialise;
  c_ClownZ80_Constant_Initialise;

end.

