unit NES.Mapper.StudyBox;

interface

uses
  Audio.Types, NES.Mapper, NES.State, NES.StudyBox.Media, NES.Types;

type
  TMapperStudyBox = class(TMapper)
  private
    const
    // Seek time and startup latency measured in NTSC CPU cycles.
      SeekCycles = 3000000;
      BitReadyCycles = 100;
      FirstByteCycles = 7820;
      ByteCycles = 3355; // Nine bits at 4800 bps.
      PageNumberOffset = 5;
  private
    type
      TDrive = packed record
        Control, Command, CommandBits: Byte;
        Ready, PageFound, InDataRegion, Interrupt, Playing: Boolean;
        ReadyDelay, ByteDelay, SeekDelay: Integer;
        LeadInDelay: Int64;
        PageNumber, TargetPage, PageIndex, ByteIndex: Integer;
        AudioFrame, AudioPhase: Integer;
      end;
  private
    FPrg: TByteArray;
    FChr: array[0..$1FFF] of Byte;
    FRam: array[0..$FFFF] of Byte;
    FRamBankA, FRamBankB, FPrgBank: Integer;
    FDrive: TDrive;
    FMedia: TStudyBoxMedia;
    FCpuHz: Integer;
    FAudioSeek: IAudioSeekSource;
    FAudioBuffer: array[0..511] of SmallInt;
    FAudioStart, FAudioEnd: Integer;
    FAudioOutput: Double;
    function RamIndex(Address: Word): Integer; inline;
    procedure ControlWrite(Value: Byte);
    procedure ExecuteCommand(Value: Byte);
    procedure StartPage(Index: Integer);
    procedure ClockAudio;
  public
    constructor Create(const Prg: NES.Types.TByteArray); overload;
    constructor Create(const Prg: NES.Types.TByteArray; const Media: TStudyBoxMedia); overload;
    function CpuRead(Address: Word; out Value: Byte): Boolean; override;
    function CpuPeek(Address: Word; out Value: Byte): Boolean; override;
    function CpuWrite(Address: Word; Value: Byte): Boolean; override;
    function PpuRead(Address: Word; out Value: Byte): Boolean; override;
    function PpuWrite(Address: Word; Value: Byte): Boolean; override;
    function GetMirrorMode: TMirrorMode; override;
    procedure SetRegion(Region: TNesRegion); override;
    procedure ClockCpu; override;
    function IrqPending: Boolean; override;
    function ExpansionAudio: Double; override;
    procedure PowerOn; override;
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
  end;

implementation

uses
  System.Classes, System.SysUtils, System.Math, NES.Consts;

constructor TMapperStudyBox.Create(const Prg: NES.Types.TByteArray);
begin
  Create(Prg, Default(TStudyBoxMedia));
end;

constructor TMapperStudyBox.Create(const Prg: NES.Types.TByteArray; const Media: TStudyBoxMedia);
begin
  inherited Create;
  if Length(Prg) <> STUDY_BOX_BIOS_SIZE then
    raise ENesException.Create('StudyBox requires a 256 KiB program ROM');
  FPrg := Prg;
  FMedia := Media;
  if Assigned(FMedia.Audio) then
    Supports(FMedia.Audio, IAudioSeekSource, FAudioSeek);
  FCpuHz := NES_CPU_HZ;
  Reset;
end;

function TMapperStudyBox.RamIndex(Address: Word): Integer;
begin
  case Address shr 12 of
    4:
      Result := $8000 + (Address and $FFF);
    5:
      Result := $8000 + FRamBankA * $1000 + (Address and $FFF);
  else
    Result := FRamBankB * $2000 + (Address and $1FFF);
  end;
end;

function TMapperStudyBox.CpuPeek(Address: Word; out Value: Byte): Boolean;
begin
  Result := True;
  case Address of
    $4200..$43FF:
      case Address and 3 of
        0:
          begin
            Value := $AA;
            if FDrive.ByteIndex >= 0 then
            begin
              if FDrive.ByteIndex < Length(FMedia.Pages[FDrive.PageIndex].Data) then
                Value := FMedia.Pages[FDrive.PageIndex].Data[FDrive.ByteIndex];
            end;
          end;
        1:
          Value := (Ord(FDrive.InDataRegion) shl 5) or (Ord(FDrive.PageFound) shl 6) or
            ((FDrive.Control and 1) shl 7);
        2:
          Value := Ord(FDrive.Ready) shl 6;
      else
        Value := 0;
      end;
    $4400..$7FFF:
      Value := FRam[RamIndex(Address)];
    $8000..$BFFF:
      Value := FPrg[FPrgBank * $4000 + (Address and $3FFF)];
    $C000..$FFFF:
      Value := FPrg[Address and $3FFF];
  else
    Result := False;
  end;
end;

function TMapperStudyBox.CpuRead(Address: Word; out Value: Byte): Boolean;
begin
  Result := CpuPeek(Address, Value);
  if (Address >= $4200) and (Address <= $43FF) then
    case Address and 3 of
      0:
        FDrive.Interrupt := False;
      1:
        FDrive.PageFound := False;
    end;
end;

function TMapperStudyBox.CpuWrite(Address: Word; Value: Byte): Boolean;
begin
  Result := True;
  case Address of
    $4200..$43FF:
      case Address and 3 of
        0:
          begin
            FRamBankA := Value and 7;
            FRamBankB := Value shr 6;
          end;
        1:
          FPrgBank := Value and $0F;
        2:
          ControlWrite(Value);
      end;
    $4400..$7FFF:
      FRam[RamIndex(Address)] := Value;
  else
    Result := False;
  end;
end;

function TMapperStudyBox.PpuRead(Address: Word; out Value: Byte): Boolean;
begin
  Result := Address < $2000;
  if Result then
    Value := FChr[Address];
end;

function TMapperStudyBox.PpuWrite(Address: Word; Value: Byte): Boolean;
begin
  Result := Address < $2000;
  if Result then
    FChr[Address] := Value;
end;

function TMapperStudyBox.GetMirrorMode: TMirrorMode;
begin
  Result := TMirrorMode.FourScreen;
end;

procedure TMapperStudyBox.SetRegion(Region: TNesRegion);
begin
  var NewHz := CpuFrequency(Region);
  FDrive.AudioPhase := (Int64(FDrive.AudioPhase) * NewHz) div FCpuHz;
  FCpuHz := NewHz;
end;

procedure TMapperStudyBox.ControlWrite(Value: Byte);
begin
  var Falling := FDrive.Control and not Value;
  FDrive.Control := Value;
  FDrive.Interrupt := False;
  if (Falling and $10) <> 0 then
  begin
    FDrive.Command := ((FDrive.Command shl 1) or (Value shr 7)) and $FF;
    Inc(FDrive.CommandBits);
    if FDrive.CommandBits = 8 then
    begin
      ExecuteCommand(FDrive.Command);
      FDrive.CommandBits := 0;
    end;
  end;
  if (Value and $10) <> 0 then
  begin
    FDrive.Ready := False;
    FDrive.ReadyDelay := BitReadyCycles;
  end;
  if (Falling and $20) <> 0 then
  begin
    FDrive.Command := 0;
    FDrive.CommandBits := 0;
    FDrive.Ready := True;
    FDrive.ReadyDelay := 0;
  end;
  if (Value and 4) <> 0 then
    FAudioOutput := 0;
end;

procedure TMapperStudyBox.ExecuteCommand(Value: Byte);
begin
  if Length(FMedia.Pages) = 0 then
    Exit;
  case Value of
    0:
      FDrive.TargetPage := FDrive.PageNumber;
    1..$3F:
      FDrive.TargetPage := FDrive.PageNumber + Value;
    $41..$7F:
      FDrive.TargetPage := FDrive.PageNumber - (Value and $3F);
    $86:
      begin
        // Consecutive blocks can carry the same logical page number.
        StartPage((FDrive.PageIndex + 1) mod Length(FMedia.Pages));
        Exit;
      end;
  else
    Exit;
  end;
  FDrive.TargetPage := EnsureRange(FDrive.TargetPage, 0, 256);
  var Distance := Abs(FDrive.TargetPage - FDrive.PageNumber);
  FDrive.SeekDelay := Max(1, Distance) * SeekCycles;
  FDrive.LeadInDelay := 0;
  FDrive.ByteDelay := 0;
  FDrive.PageFound := False;
  FDrive.InDataRegion := False;
  FDrive.Playing := False;
  FAudioOutput := 0;
end;

procedure TMapperStudyBox.StartPage(Index: Integer);
begin
  FDrive.PageIndex := Index;
  FDrive.ByteIndex := -1;
  FDrive.ByteDelay := 0;
  FDrive.SeekDelay := 0;
  FDrive.AudioPhase := 0;
  FDrive.Playing := False;
  FAudioOutput := 0;
  var Page := FMedia.Pages[Index];
  FDrive.PageNumber := Page.Data[PageNumberOffset] + 1;
  FDrive.LeadInDelay := Max(Int64(1), Int64(Page.AudioStart - Page.LeadIn) * FCpuHz div FMedia.SampleRate);
  FDrive.PageFound := True;
  FDrive.InDataRegion := True;
end;

procedure TMapperStudyBox.ClockAudio;
begin
  if FDrive.AudioFrame >= FMedia.AudioFrames then
  begin
    FDrive.Playing := False;
    FAudioOutput := 0;
    Exit;
  end;
  if (FDrive.AudioFrame < FAudioStart) or (FDrive.AudioFrame >= FAudioEnd) then
  begin
    FAudioStart := FDrive.AudioFrame;
    FAudioSeek.SeekFrame(FAudioStart, nil);
    FAudioEnd := FAudioStart + FMedia.Audio.Render(FAudioBuffer, Length(FAudioBuffer));
  end;
  if (FDrive.Control and 4 = 0) and (FDrive.AudioFrame < FAudioEnd) then
    FAudioOutput := FAudioBuffer[FDrive.AudioFrame - FAudioStart] * (0.5 / 32768.0);
  Inc(FDrive.AudioPhase, FMedia.SampleRate);
  if FDrive.AudioPhase >= FCpuHz then
  begin
    Dec(FDrive.AudioPhase, FCpuHz);
    Inc(FDrive.AudioFrame);
  end;
end;

procedure TMapperStudyBox.ClockCpu;
begin
  if FDrive.ReadyDelay > 0 then
  begin
    Dec(FDrive.ReadyDelay);
    if FDrive.ReadyDelay = 0 then
      FDrive.Ready := True;
  end;

  if FDrive.SeekDelay > 0 then
  begin
    Dec(FDrive.SeekDelay);
    if FDrive.SeekDelay = 0 then
    begin
      var Index := 0;
      for var N := 0 to High(FMedia.Pages) do
        if FMedia.Pages[N].Data[PageNumberOffset] + 1 = FDrive.TargetPage then
        begin
          Index := N;
          Break;
        end;
      StartPage(Index);
    end;
  end
  else if FDrive.LeadInDelay > 0 then
  begin
    Dec(FDrive.LeadInDelay);
    if FDrive.LeadInDelay = 0 then
    begin
      FDrive.ByteDelay := FirstByteCycles;
      FDrive.AudioFrame := FMedia.Pages[FDrive.PageIndex].AudioStart;
      FDrive.Playing := Assigned(FAudioSeek);
      // The lead-in first asserts IRQ with the sync byte still in the latch.
      FDrive.Interrupt := True;
    end;
  end
  else if FDrive.ByteDelay > 0 then
  begin
    Dec(FDrive.ByteDelay);
    if FDrive.ByteDelay = 0 then
    begin
      Inc(FDrive.ByteIndex);
      if FDrive.ByteIndex < Length(FMedia.Pages[FDrive.PageIndex].Data) then
        FDrive.ByteDelay := ByteCycles
      else
      begin
        FDrive.InDataRegion := False;
        FDrive.PageFound := False;
        FDrive.Playing := False;
        FAudioOutput := 0;
      end;
      if (FDrive.Control and 2) <> 0 then
        FDrive.Interrupt := True;
    end;
  end;

  if FDrive.Playing then
    ClockAudio;
end;

function TMapperStudyBox.IrqPending: Boolean;
begin
  Result := FDrive.Interrupt;
end;

function TMapperStudyBox.ExpansionAudio: Double;
begin
  Result := FAudioOutput;
end;

procedure TMapperStudyBox.PowerOn;
begin
  FillChar(FRam, SizeOf(FRam), 0);
  FillChar(FChr, SizeOf(FChr), 0);
  Reset;
end;

procedure TMapperStudyBox.Reset;
begin
  FRamBankA := 0;
  FRamBankB := 0;
  FPrgBank := 0;
  FDrive := Default(TDrive);
  FDrive.ByteIndex := -1;
  FAudioOutput := 0;
end;

procedure TMapperStudyBox.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FRam, SizeOf(FRam));
  State.Field(FChr, SizeOf(FChr));
  State.Field(FRamBankA, SizeOf(FRamBankA));
  State.Field(FRamBankB, SizeOf(FRamBankB));
  State.Field(FPrgBank, SizeOf(FPrgBank));
  State.Field(FDrive, SizeOf(FDrive));
  State.Field(FAudioOutput, SizeOf(FAudioOutput));
  if State.Loading then
  begin
    if (Cardinal(FRamBankA) > 7) or (Cardinal(FRamBankB) > 3) or
      (Cardinal(FPrgBank) > 15) or (FDrive.CommandBits > 7) or
      (FDrive.ByteIndex < -1) or (FDrive.ReadyDelay < 0) or
      (FDrive.SeekDelay < 0) or (FDrive.LeadInDelay < 0) or (FDrive.ByteDelay < 0) or
      (Cardinal(FDrive.AudioFrame) > Cardinal(FMedia.AudioFrames)) or
      (Cardinal(FDrive.AudioPhase) >= Cardinal(FCpuHz)) or
      IsNan(FAudioOutput) or (Abs(FAudioOutput) > 0.5) then
      raise EReadError.Create('Invalid StudyBox state');
    if Length(FMedia.Pages) = 0 then
    begin
      if (FDrive.ByteIndex >= 0) or (FDrive.SeekDelay <> 0) or
        (FDrive.LeadInDelay <> 0) or (FDrive.ByteDelay <> 0) then
        raise EReadError.Create('StudyBox state requires a tape');
    end
    else if (Cardinal(FDrive.PageIndex) >= Cardinal(Length(FMedia.Pages))) or
      (FDrive.ByteIndex > Length(FMedia.Pages[FDrive.PageIndex].Data)) then
      raise EReadError.Create('Invalid StudyBox tape position');
    if FDrive.Playing and not Assigned(FAudioSeek) then
      raise EReadError.Create('StudyBox state requires tape audio');
  end;
end;

end.

