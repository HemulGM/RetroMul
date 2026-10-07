unit RetroTune.Decoder.SAA;

interface

implementation

uses
  System.SysUtils, System.Math, System.Generics.Collections, RetroTune.Decoder,
  RetroTune.Binary, RetroTune.ETracker, SAM.Sound.SAA1099;

type
  TSAAStreamDecoder = class(TInterfacedObject, ITuneDecoder)
  private
    FSongs: TArray<TETrackerSong>;
    FChip: TSAA1099;
    FInfo: TTuneInfo;
    FTrack, FFrame, FRemaining: Integer;
  public
    constructor Create(const Songs: TArray<TETrackerSong>; const Names: TArray<string>; const Kind: string);
    destructor Destroy; override;
    function GetInfo: TTuneInfo;
    procedure SelectTrack(Index: Integer);
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer;
  end;

constructor TSAAStreamDecoder.Create(const Songs: TArray<TETrackerSong>; const Names: TArray<string>; const Kind: string);
begin
  inherited Create;
  if Length(Songs) = 0 then
    raise EArgumentException.Create('No SAA1099 songs');
  FSongs := Copy(Songs);
  FInfo.FormatName := Kind;
  FInfo.TrackCount := Length(Songs);
  FInfo.TrackNames := Copy(Names);
  FInfo.SampleRate := 44100;
  FInfo.Channels := 2;
  FInfo.Details := 'E-Tracker, SAA1099, 8 MHz, six stereo voices';
  SetLength(FInfo.TrackDurations, Length(Songs));
  for var I := 0 to High(Songs) do
    FInfo.TrackDurations[I] := Length(Songs[I].Frames) / 50.0;
  if Length(Names) > 0 then
    FInfo.Title := Names[0];
  FChip := TSAA1099.Create;
  SelectTrack(0);
end;

destructor TSAAStreamDecoder.Destroy;
begin
  FChip.Free;
  inherited;
end;

function TSAAStreamDecoder.GetInfo: TTuneInfo;
begin
  Result := FInfo;
end;

procedure TSAAStreamDecoder.SelectTrack(Index: Integer);
begin
  if (Index < 0) or (Index >= Length(FSongs)) then
    raise EArgumentOutOfRangeException.Create('SAA track');
  FTrack := Index;
  FFrame := 0;
  FRemaining := 0;
  FChip.Reset;
end;

function TSAAStreamDecoder.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
begin
  ValidateRender(Length(Samples), Frames, 2);
  Result := 0;
  while Result < Frames do
  begin
    if FRemaining = 0 then
    begin
      if FFrame = Length(FSongs[FTrack].Frames) then
        Break;
      for var W in FSongs[FTrack].Frames[FFrame] do
        FChip.WriteRegister(W.RegisterID, W.Value);
      Inc(FFrame);
      FRemaining := 882;
    end;
    FChip.Sample(Samples[Result * 2], Samples[Result * 2 + 1]);
    Inc(Result);
    Dec(FRemaining);
  end;
end;

function OpenCOP(const Data: TBytes): ITuneDecoder;
begin
  Result := TSAAStreamDecoder.Create([CompileETracker(Data)], nil, 'COP/ETC');
end;

function OpenSNG(const Data: TBytes): ITuneDecoder;
begin
  Result := TSAAStreamDecoder.Create([CompileETracker(Data)], nil, 'SNG');
end;

function OpenTAP(const Data: TBytes): ITuneDecoder;
var
  Songs: TList<TETrackerSong>;
  Names: TList<string>;
begin
  Songs := TList<TETrackerSong>.Create;
  Names := TList<string>.Create;
  try
    var At := 0;
    var Name := '';
    var Total := 0;
    while At < Length(Data) do
    begin
      var Size := Integer(LE16(Data, At));
      Inc(At, 2);
      RequireBytes(Data, At, Size);
      if Size < 2 then
        raise EArgumentException.Create('Short TAP block');
      var Checksum := 0;
      for var I := 0 to Size - 1 do
        Checksum := Checksum xor Data[At + I];
      if Checksum <> 0 then
        raise EArgumentException.Create('TAP block checksum mismatch');
      if (Size = 19) and (Data[At] = 0) then
        Name := TextField(Data, At + 2, 10)
      else if Data[At] = $FF then
      begin
        // Strip tape flag/checksum and find self-contained E-Tracker modules.
        for var P := At + 11 to At + Size - 9 do
          if (Data[P] = Ord('E')) and (TEncoding.ASCII.GetString(Data, P, 8) = 'ETracker') then
          begin
            var Start := P - 10;
            if Start < At + 1 then
              Continue;
            var Song := CompileETracker(Copy(Data, Start, At + Size - 1 - Start));
            if Songs.Count >= 256 then
              raise EArgumentException.Create('Too many TAP songs');
            Inc(Total, Length(Song.Frames));
            if Total > 1800000 then
              raise EArgumentException.Create('TAP exceeds total frame limit');
            Songs.Add(Song);
            Names.Add(Name);
            Break;
          end;
      end;
      Inc(At, Size);
    end;
    if Songs.Count = 0 then
      raise ENotSupportedException.Create('TAP contains no supported E-Tracker modules');
    Result := TSAAStreamDecoder.Create(Songs.ToArray, Names.ToArray, 'TAP');
  finally
    Names.Free;
    Songs.Free;
  end;
end;

initialization
  TTuneDecoders.RegisterFormat('.sng', 'SAM Coupe E-Tracker / SAA1099', OpenSNG);
  TTuneDecoders.RegisterFormat('.cop', 'E-Tracker / SAA1099', OpenCOP);
  TTuneDecoders.RegisterFormat('.etc', 'E-Tracker / SAA1099', OpenCOP);
  TTuneDecoders.RegisterFormat('.tap', 'Spectrum tape with E-Tracker music', OpenTAP);

end.

