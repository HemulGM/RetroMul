unit MSX.Cassette;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, SG1000.Cassette;

type
  TMSXCassette = class
  private
    FWave: TSGCassette;
    FData: TBytes;
    FCAS, FPlaying, FMotor, FSignal: Boolean;
    FBaud, FStage, FPosition, FLeaderEdges, FBit, FEdges: Integer;
    FUntilEdge: Int64;
    function HeaderAt(Position: Integer): Boolean;
    procedure StartBlock;
    procedure StartBit;
    procedure Edge;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Load(const Data: TBytes; CAS: Boolean; Baud: Integer = 1200);
    procedure Rewind;
    procedure Play;
    procedure Stop;
    procedure RecordTape;
    procedure SetLines(Motor, Output: Boolean);
    procedure Advance(Cycles: Integer);
    function Input: Boolean;
    function Recording: Boolean;
    function SaveWAV: TBytes;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

const
  CASHeader: array[0..7] of Byte = ($1F, $A6, $DE, $BA, $CC, $13, $7D, $74);
  CPUClock = 3579545;

constructor TMSXCassette.Create;
begin
  inherited;
  FWave := TSGCassette.Create;
  FBaud := 1200;
end;

destructor TMSXCassette.Destroy;
begin
  FWave.Free;
  inherited;
end;

function TMSXCassette.HeaderAt(Position: Integer): Boolean;
begin
  Result := False;
  if (Position and 7 <> 0) or (Position < 0) or (Position > Length(FData) - 8) then
    Exit;
  Result := CompareMem(@FData[Position], @CASHeader[0], 8);
end;

procedure TMSXCassette.Load(const Data: TBytes; CAS: Boolean; Baud: Integer);
begin
  if CAS then
  begin
    if (Baud <> 1200) and (Baud <> 2400) then
      raise EReadError.Create('CAS speed must be 1200 or 2400 baud');
    if (Length(Data) < 8) or not CompareMem(@Data[0], @CASHeader[0], 8) then
      raise EReadError.Create('MSX CAS header is missing');
    if Length(Data) > 16 * 1024 * 1024 then
      raise EReadError.Create('MSX CAS exceeds 16 MiB');
    FWave.RecordTape;
    FWave.Stop;
    FData := Copy(Data);
    FBaud := Baud;
    FCAS := True;
  end
  else
  begin
    FWave.LoadWAV(Data);
    FData := nil;
    FCAS := False;
  end;
  Rewind;
end;

procedure TMSXCassette.StartBlock;
begin
  // Header markers are container delimiters, not bytes on the wire.
  Inc(FPosition, 8);
  var LongLeader := FPosition = 8;
  if FPosition + 10 <= Length(FData) then
  begin
    var Kind := FData[FPosition];
    if Kind in [$D0, $D3, $EA] then
    begin
      var Same := True;
      for var I := 1 to 9 do
        Same := Same and (FData[FPosition + I] = Kind);
      LongLeader := LongLeader or Same;
    end;
  end;
  FLeaderEdges := 8000;
  if LongLeader then
    FLeaderEdges := 32000;
  if FBaud = 2400 then
    FLeaderEdges := FLeaderEdges * 2;
  FStage := 0;
  FSignal := False;
  // One second of silence lets the recorder settle after motor-on.
  Inc(FUntilEdge, Int64(CPUClock) * 9600);
end;

procedure TMSXCassette.Rewind;
begin
  FWave.Rewind;
  FPlaying := False;
  FPosition := 0;
  FStage := 3;
  FBit := 0;
  FEdges := 0;
  FSignal := True;
  FUntilEdge := 0;
  FLeaderEdges := 0;
  if FCAS then
    StartBlock;
end;

procedure TMSXCassette.Play;
begin
  if FCAS then
    FPlaying := True
  else
    FWave.Play;
end;

procedure TMSXCassette.Stop;
begin
  FPlaying := False;
  FWave.Stop;
end;

procedure TMSXCassette.RecordTape;
begin
  FData := nil;
  FCAS := False;
  FPlaying := False;
  FWave.RecordTape;
end;

procedure TMSXCassette.SetLines(Motor, Output: Boolean);
begin
  FMotor := Motor;
  FWave.SetOutput(Output);
end;

procedure TMSXCassette.StartBit;
begin
  var Mark := False;
  if FBit >= 9 then
    Mark := True
  else if FBit > 0 then
    Mark := FData[FPosition] and (1 shl (FBit - 1)) <> 0;
  FEdges := 2;
  var Units := 4;
  if Mark then
  begin
    FEdges := 4;
    Units := 2;
  end;
  if FBaud = 2400 then
    Units := Units div 2;
  Inc(FUntilEdge, Int64(CPUClock) * Units);
end;

procedure TMSXCassette.Edge;
begin
  case FStage of
    0:
      begin
        FStage := 1;
        FSignal := False;
        Inc(FUntilEdge, Int64(CPUClock) * (2400 div FBaud));
      end;
    1:
      begin
        FSignal := not FSignal;
        Dec(FLeaderEdges);
        if FLeaderEdges > 0 then
          Inc(FUntilEdge, Int64(CPUClock) * (2400 div FBaud))
        else
        begin
          if FPosition >= Length(FData) then
          begin
            FPlaying := False;
            FStage := 3;
            FUntilEdge := 0;
            Exit;
          end;
          FStage := 2;
          FBit := 0;
          FSignal := False;
          StartBit;
        end;
      end;
    2:
      begin
        FSignal := not FSignal;
        Dec(FEdges);
        if FEdges > 0 then
        begin
          var Mark := FBit >= 9;
          if (FBit > 0) and (FBit < 9) then
            Mark := FData[FPosition] and (1 shl (FBit - 1)) <> 0;
          var Units := 4;
          if Mark then
            Units := 2;
          if FBaud = 2400 then
            Units := Units div 2;
          Inc(FUntilEdge, Int64(CPUClock) * Units);
        end
        else
        begin
          Inc(FBit);
          if FBit = 11 then
          begin
            Inc(FPosition);
            FBit := 0;
            if FPosition >= Length(FData) then
            begin
              FStage := 3;
              FPlaying := False;
              FUntilEdge := 0;
              Exit;
            end;
            if HeaderAt(FPosition) then
            begin
              StartBlock;
              Exit;
            end;
          end;
          StartBit;
        end;
      end;
  end;
end;

procedure TMSXCassette.Advance(Cycles: Integer);
begin
  if Cycles < 0 then
    raise EArgumentOutOfRangeException.Create('Cassette clocks');
  if not FMotor then
    Exit;
  if not FCAS then
  begin
    while Cycles > 0 do
    begin
      var Chunk := Cycles;
      if Chunk > 65535 then
        Chunk := 65535;
      FWave.Advance(Chunk, CPUClock);
      Dec(Cycles, Chunk);
    end;
    Exit;
  end;
  if not FPlaying then
    Exit;
  Dec(FUntilEdge, Int64(Cycles) * 9600);
  while FPlaying and (FUntilEdge <= 0) do
    Edge;
end;

function TMSXCassette.Input: Boolean;
begin
  Result := True;
  if not FMotor then
    Exit;
  if FCAS then
  begin
    if FPlaying then
      Result := FSignal;
  end
  else if FWave.Playing then
    Result := FWave.Input;
end;

function TMSXCassette.Recording: Boolean;
begin
  Result := FWave.Recording;
end;

function TMSXCassette.SaveWAV: TBytes;
begin
  Result := FWave.SaveWAV;
end;

procedure TMSXCassette.SerializeState(State: TStateArchive);
begin
  var N := Length(FData);
  State.Field(N, SizeOf(N));
  if (N < 0) or (N > 16 * 1024 * 1024) then
    raise EReadError.Create('Invalid MSX CAS state size');
  if State.Loading then
    SetLength(FData, N);
  if N > 0 then
    State.Field(FData[0], N);
  State.Field(FCAS, SizeOf(FCAS));
  State.Field(FPlaying, SizeOf(FPlaying));
  State.Field(FMotor, SizeOf(FMotor));
  State.Field(FSignal, SizeOf(FSignal));
  State.Field(FBaud, SizeOf(FBaud));
  State.Field(FStage, SizeOf(FStage));
  State.Field(FPosition, SizeOf(FPosition));
  State.Field(FLeaderEdges, SizeOf(FLeaderEdges));
  State.Field(FBit, SizeOf(FBit));
  State.Field(FEdges, SizeOf(FEdges));
  State.Field(FUntilEdge, SizeOf(FUntilEdge));
  FWave.SerializeState(State);
  if State.Loading and (((FBaud <> 1200) and (FBaud <> 2400)) or (FStage < 0) or (FStage > 3) or
    (FPosition < 0) or (FPosition > N) or (FBit < 0) or (FBit > 10) or (FEdges < 0) or (FEdges > 4) or
    (FLeaderEdges < 0) or (FLeaderEdges > 64000) or (FUntilEdge < 0) or (FUntilEdge > Int64(CPUClock) * 9600) or
    (FCAS and (N < 8))) then
    raise EReadError.Create('Invalid MSX cassette state');
end;

end.

