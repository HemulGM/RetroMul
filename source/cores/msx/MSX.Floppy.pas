unit MSX.Floppy;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, ZX.BetaDisk;

type
  TMSXWD2793 = class(TZXBetaDisk)
  private
    FDrive, FSide: Byte;
    FClockPhase: Integer;
    FChanged: array[0..1] of Boolean;
    FSources: array[0..1] of string;
  protected
    function Selected: Integer; override;
    function Head: Integer; override;
    function Ready: Boolean; override;
  public
    procedure Reset; override;
    procedure SetSide(Value: Byte);
    procedure SetDrive(Value: Byte);
    procedure MountImage(const Data: TBytes; Drive: Integer; ReadOnly: Boolean; const SourceIdentity: string = '');
    procedure Eject(Drive: Integer);
    procedure AdvanceHost(Cycles: Integer);
    function ReadRegister(Index: Integer): Byte;
    procedure WriteRegister(Index: Integer; Value: Byte);
    procedure SerializeMSX(State: TStateArchive);
    function MediaIdentity: string;
  end;

  TMSXFloppy = class
  private
    FController: TMSXWD2793;
    FOriginalROM, FROM: TBytes;
  public
    constructor Create;
    destructor Destroy; override;
    procedure SetROM(const Data: TBytes);
    function Enabled: Boolean;
    procedure Reset;
    function ReadMemory(Address: Word): Byte;
    procedure WriteMemory(Address: Word; Value: Byte);
    procedure Advance(Cycles: Integer);
    procedure SerializeState(State: TStateArchive);
    function Identity: string;
    property Controller: TMSXWD2793 read FController;
  end;

implementation

function TMSXWD2793.Selected: Integer;
begin
  Result := 0;
  case FDrive and 3 of
    1:
      Result := 1;
    3:
      Result := 2;
  end;
end;

function TMSXWD2793.Head: Integer;
begin
  Result := FSide and 1;
end;

function TMSXWD2793.Ready: Boolean;
begin
  Result := (Selected < 2) and (FDrive and $80 <> 0) and (Disk(Selected) <> nil);
end;

procedure TMSXWD2793.Reset;
begin
  var Tracks: array[0..3] of Integer;
  Move(FPhysicalTrack, Tracks, SizeOf(Tracks));
  inherited;
  Move(Tracks, FPhysicalTrack, SizeOf(Tracks));
  FDrive := 3;
  FSide := 0;
  FClockPhase := 0;
end;

procedure TMSXWD2793.SetSide(Value: Byte);
begin
  if FBusy and ((Value xor FSide) and 1 <> 0) then
    Finish($10);
  FSide := Value;
end;

procedure TMSXWD2793.SetDrive(Value: Byte);
begin
  var OldReady := Ready;
  var OldDrive := Selected;
  FDrive := Value;
  if FBusy and ((OldDrive <> Selected) or not Ready) then
    Finish($10);
  if (FForce and 1 <> 0) and not OldReady and Ready then
    FINTRQ := True;
  if (FForce and 2 <> 0) and OldReady and not Ready then
    FINTRQ := True;
end;

procedure TMSXWD2793.MountImage(const Data: TBytes; Drive: Integer; ReadOnly: Boolean; const SourceIdentity: string);
begin
  if not (Drive in [0, 1]) then
    raise EArgumentOutOfRangeException.Create('MSX floppy drive');
  if (Length(Data) < 512) or (Length(Data) > 86 * 2 * 9 * 512) or (Length(Data) mod 512 <> 0) then
    raise EReadError.Create('MSX disk must contain complete 512-byte sectors');
  var Heads := 0;
  var Sectors := 0;
  var Cylinders: Integer;
  var WasReady := Ready;
  // Prefer a consistent FAT BPB; 360/320 KiB can be 80x1 or 40x2 media.
  var BPBSectors := Integer(Data[24]) or (Integer(Data[25]) shl 8);
  var BPBHeads := Integer(Data[26]) or (Integer(Data[27]) shl 8);
  var BytesPerSector := Integer(Data[11]) or (Integer(Data[12]) shl 8);
  if (BytesPerSector = 512) and (BPBSectors in [8, 9]) and (BPBHeads in [1, 2]) and
    (Length(Data) mod (512 * BPBSectors * BPBHeads) = 0) then
  begin
    Sectors := BPBSectors;
    Heads := BPBHeads;
  end
  else
    case Length(Data) div 1024 of
      160:
        begin
          Sectors := 8;
          Heads := 1;
        end;
      180:
        begin
          Sectors := 9;
          Heads := 1;
        end;
      320:
        begin
          Sectors := 8;
          Heads := 1;
          if Data[21] = $FF then
            Heads := 2;
        end;
      360:
        begin
          Sectors := 9;
          Heads := 1;
          if Data[21] = $FD then
            Heads := 2;
        end;
      640:
        begin
          Sectors := 8;
          Heads := 2;
        end;
      720:
        begin
          Sectors := 9;
          Heads := 2;
        end;
    end;
  if Heads = 0 then
    raise EReadError.Create('Unsupported MSX disk geometry (8/9 sectors, 1/2 sides)');
  Cylinders := Length(Data) div (Heads * Sectors * 512);
  MountRaw(Data, Cylinders, Heads, Sectors, 512, Drive);
  Disk(Drive).WriteProtected := ReadOnly;
  FSources[Drive] := SnapshotIdentity(Data);
  if SourceIdentity <> '' then
    FSources[Drive] := SourceIdentity;
  FChanged[Drive] := True;
  if (FForce and 1 <> 0) and not WasReady and Ready then
    FINTRQ := True;
end;

procedure TMSXWD2793.Eject(Drive: Integer);
begin
  if not (Drive in [0, 1]) then
    raise EArgumentOutOfRangeException.Create('MSX floppy drive');
  var WasReady := Ready;
  if FBusy and (Selected = Drive) then
    Finish($80);
  FreeAndNil(FDisks[Drive]);
  FChanged[Drive] := True;
  InvalidateTrackCache;
  FSources[Drive] := '';
  if (FForce and 2 <> 0) and WasReady and not Ready then
    FINTRQ := True;
end;

procedure TMSXWD2793.AdvanceHost(Cycles: Integer);
begin
  var T := Int64(FClockPhase) + Int64(Cycles) * 3500000;
  inherited Advance(T div 3579545);
  FClockPhase := T mod 3579545;
  // The drive clears its disk-change switch after the head is stepped.
  // Keep the latch until a step command actually moves a mounted drive.
end;

function TMSXWD2793.ReadRegister(Index: Integer): Byte;
const
  Ports: array[0..3] of Byte = ($1F, $3F, $5F, $7F);
begin
  case Index of
    0..3:
      Result := ReadPort(Ports[Index]);
    4:
      Result := FSide;
    5:
      begin
        Result := FDrive and $FB;
        if (Selected >= 2) or not FChanged[Selected] then
          Result := Result or 4;
      end;
    7:
      begin
        Result := $FF;
        if INTRQ then
          Result := Result and $BF;
        if DRQ then
          Result := Result and $7F;
      end;
  else
    Result := $FF;
  end;
end;

procedure TMSXWD2793.WriteRegister(Index: Integer; Value: Byte);
const
  Ports: array[0..3] of Byte = ($1F, $3F, $5F, $7F);
begin
  case Index of
    0..3:
      begin
        var OldTrack := FPhysicalTrack[Selected];
        WritePort(Ports[Index], Value);
        if (Index = 0) and (Selected < 2) and (Disk(Selected) <> nil) and
          ((OldTrack <> FPhysicalTrack[Selected]) or (Value and $F0 = 0)) then
          FChanged[Selected] := False;
      end;
    4:
      SetSide(Value);
    5:
      SetDrive(Value);
  end;
end;

procedure TMSXWD2793.SerializeMSX(State: TStateArchive);
begin
  State.Field(FDrive, SizeOf(FDrive));
  State.Field(FSide, SizeOf(FSide));
  State.Field(FClockPhase, SizeOf(FClockPhase));
  State.Field(FChanged, SizeOf(FChanged));
  inherited SerializeState(State);
  if State.Loading and ((FClockPhase < 0) or (FClockPhase >= 3579545)) then
    raise EReadError.Create('Invalid MSX FDC clock');
end;

function TMSXWD2793.MediaIdentity: string;
begin
  Result := FSources[0] + '|' + FSources[1];
end;

constructor TMSXFloppy.Create;
begin
  inherited;
  FController := TMSXWD2793.Create;
end;

destructor TMSXFloppy.Destroy;
begin
  FController.Free;
  inherited;
end;

procedure TMSXFloppy.SetROM(const Data: TBytes);
begin
  if (Length(Data) <> 0) and (Length(Data) <> $4000) then
    raise EReadError.Create('Philips MSX disk ROM must be 16 KiB');
  FOriginalROM := Copy(Data);
  FROM := Copy(Data);
  Reset;
end;

function TMSXFloppy.Enabled: Boolean;
begin
  Result := Length(FROM) > 0;
end;

procedure TMSXFloppy.Reset;
begin
  FController.Reset;
end;

function TMSXFloppy.ReadMemory(Address: Word): Byte;
begin
  Result := $FF;
  if not Enabled then
    Exit;
  if Address and $3FFF >= $3FF8 then
    Exit(FController.ReadRegister(Address and 7));
  if (Address >= $4000) and (Address < $8000) then
    Result := FROM[Address and $3FFF];
end;

procedure TMSXFloppy.WriteMemory(Address: Word; Value: Byte);
begin
  if Enabled and (Address and $3FFF >= $3FF8) then
    FController.WriteRegister(Address and 7, Value);
end;

procedure TMSXFloppy.Advance(Cycles: Integer);
begin
  if Enabled then
    FController.AdvanceHost(Cycles);
end;

procedure TMSXFloppy.SerializeState(State: TStateArchive);
begin
  var Identity := TEncoding.ASCII.GetBytes(SnapshotIdentity(FOriginalROM));
  var Saved := Copy(Identity);
  State.Field(Saved[0], Length(Saved));
  if State.Loading and not CompareMem(@Saved[0], @Identity[0], Length(Saved)) then
    raise EReadError.Create('MSX disk ROM differs');
  FController.SerializeMSX(State);
end;

function TMSXFloppy.Identity: string;
begin
  Result := SnapshotIdentity(FOriginalROM) + ':' + FController.MediaIdentity;
end;

end.

