unit RetroTune.Decoder.MIDI;

interface

uses
  System.SysUtils, RetroTune.SoundFont;

// Existing decoders retain the immutable bank when another is selected.
procedure SetMidiSoundFont(const Path: string);

function MidiSoundFontName: string;

function MidiSoundFontPath: string;

implementation

uses
  System.Classes, System.IOUtils, System.Math, System.SyncObjs,
  System.Generics.Collections, System.Generics.Defaults, RetroTune.Decoder,
  RetroTune.Binary, RetroTune.SoundFontCatalog;

type
  TMidiEvent = record
    Tick, Frame: Int64;
    Order, Tempo: Integer;
    Status, A, B: Byte;
  end;

  TMidiTrack = record
    Events: TArray<TMidiEvent>;
    Frames: Int64;
    Title: string;
  end;

  TMidiDecoder = class(TInterfacedObject, ITuneDecoder)
  private
    FInfo: TTuneInfo;
    FTracks: TArray<TMidiTrack>;
    FSynth: TSoundFontSynth;
    FTrack, FEvent: Integer;
    FPosition: Int64;
    FReleased: Boolean;
  public
    constructor Create(const Input: TBytes);
    destructor Destroy; override;
    function GetInfo: TTuneInfo;
    procedure SelectTrack(Index: Integer);
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer;
  end;

var
  BankLock: TCriticalSection;
  CurrentBank: ISoundFont;
  CurrentBankPath: string;

procedure SetMidiSoundFont(const Path: string);
begin
  var FileName := Path;
  // Migrate the former resource IDs to files beside the executable.
  if Path.ToLower.StartsWith('builtin:') then
  begin
    FileName := '';
    for var Font in StandardSoundFonts(ExtractFilePath(ParamStr(0))) do
      if SameText(Path, 'builtin:' + Font.ID) then
      begin
        FileName := Font.Path;
        Break;
      end;
    if FileName = '' then
      raise EArgumentException.Create('Unknown standard SoundFont');
  end;
  var Data: TBytes;
  var Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    if (Stream.Size > 256 * 1024 * 1024) or (Stream.Size < 12) then
      raise EArgumentException.Create('SoundFont size must be between 12 bytes and 256 MiB');
    SetLength(Data, Integer(Stream.Size));
    Stream.ReadBuffer(Data[0], Length(Data));
  finally
    Stream.Free;
  end;
  var Bank: ISoundFont := TSoundFont.Create(Data);
  BankLock.Enter;
  try
    CurrentBank := Bank;
    CurrentBankPath := ExpandFileName(FileName);
  finally
    BankLock.Leave;
  end;
end;

function GetBank: ISoundFont;
begin
  BankLock.Enter;
  try
    Result := CurrentBank;
  finally
    BankLock.Leave;
  end;
  if Result <> nil then
    Exit;
  var Folder := TPath.Combine(ExtractFilePath(ParamStr(0)), 'sf2');
  var Path := '';
  for var Font in StandardSoundFonts(ExtractFilePath(ParamStr(0))) do
    if StandardSoundFontAvailable(Font.Path) then
    begin
      Path := Font.Path;
      Break;
    end;
  if (Path = '') and TDirectory.Exists(Folder) then
  begin
    var Files := TDirectory.GetFiles(Folder, '*.sf2');
    TArray.Sort<string>(Files);
    if Length(Files) <> 0 then
      Path := Files[0];
  end;
  if Path = '' then
    raise EArgumentException.Create('MIDI requires a SoundFont: place SF2 files in the sf2 folder beside the executable or select a custom SF2');
  SetMidiSoundFont(Path);
  BankLock.Enter;
  try
    Result := CurrentBank;
  finally
    BankLock.Leave;
  end;
end;

function MidiSoundFontPath: string;
begin
  BankLock.Enter;
  try
    Result := CurrentBankPath;
  finally
    BankLock.Leave;
  end;
end;

function MidiSoundFontName: string;
begin
  BankLock.Enter;
  try
    if CurrentBank = nil then
      Result := 'GeneralUser GS'
    else
      Result := CurrentBank.Name;
  finally
    BankLock.Leave;
  end;
end;

constructor TMidiDecoder.Create(const Input: TBytes);
var
  Data: TBytes;
  FormatNumber, Division, TrackCount, Sequence: Integer;
  Events: TList<TMidiEvent>;
  EndTicks: TArray<Int64>;
  Names: TArray<string>;
  Counter: Integer;

  function BE16(P: Integer): Integer;
  begin
    RequireBytes(Data, P, 2);
    Result := Integer(Data[P]) * 256 + Data[P + 1];
  end;

  function BE32(P: Integer): Cardinal;
  begin
    RequireBytes(Data, P, 4);
    Result := (Cardinal(BE16(P)) shl 16) or Cardinal(BE16(P + 2));
  end;

  function Tag(P: Integer): string;
  begin
    RequireBytes(Data, P, 4);
    Result := TEncoding.ASCII.GetString(Data, P, 4);
  end;

  procedure ParseTrack(Start, Finish, Index: Integer);
  var
    P: Integer;
    Tick: Int64;
    Running: Byte;

    function ReadByte: Byte;
    begin
      if P >= Finish then
        raise EArgumentException.Create('Truncated MIDI event');
      Result := Data[P];
      Inc(P);
    end;

    function VLQ: Integer;
    begin
      Result := 0;
      for var I := 0 to 3 do
      begin
        var B := ReadByte;
        Result := (Result shl 7) or (B and 127);
        if B < 128 then
          Exit;
      end;
      raise EArgumentException.Create('MIDI variable-length quantity exceeds four bytes');
    end;

    function Value: Byte;
    begin
      Result := ReadByte;
      if Result >= 128 then
        raise EArgumentException.Create('Invalid MIDI data byte');
    end;

    procedure Add(E: TMidiEvent);
    begin
      E.Tick := Tick;
      E.Order := Counter;
      Inc(Counter);
      Events.Add(E);
      if Events.Count > 2000000 then
        raise EArgumentException.Create('MIDI has too many events');
    end;

  begin
    P := Start;
    Tick := 0;
    Running := 0;
    while P < Finish do
    begin
      Inc(Tick, VLQ);
      if Tick > Int64(High(Integer)) * 256 then
        raise EArgumentException.Create('MIDI timeline is too long');
      var Status := ReadByte;
      if Status < 128 then
      begin
        if Running = 0 then
          raise EArgumentException.Create('MIDI running status is missing');
        Dec(P);
        Status := Running;
      end;
      var E := Default(TMidiEvent);
      if Status < $F0 then
      begin
        Running := Status;
        E.Status := Status;
        E.A := Value;
        if not ((Status and $F0) in [$C0, $D0]) then
          E.B := Value;
        Add(E);
      end
      else if Status = $FF then
      begin
        // SMF meta events preserve the previous channel running status.
        var Meta := ReadByte;
        var N := VLQ;
        if N > Finish - P then
          raise EArgumentException.Create('Truncated MIDI metadata');
        case Meta of
          $2F:
            begin
              if N <> 0 then
                raise EArgumentException.Create('Invalid MIDI end-of-track');
              P := Finish;
            end;
          $51:
            begin
              if N <> 3 then
                raise EArgumentException.Create('Invalid MIDI tempo');
              E.Tempo := Integer(Data[P]) * 65536 + Integer(Data[P + 1]) * 256 + Data[P + 2];
              if E.Tempo = 0 then
                raise EArgumentException.Create('MIDI tempo must be positive');
              Add(E);
            end;
          $03:
            if Names[Index] = '' then
              Names[Index] := TextField(Data, P, N);
          $02:
            if FInfo.CopyrightText = '' then
              FInfo.CopyrightText := TextField(Data, P, N);
        end;
        if Meta <> $2F then
          Inc(P, N);
      end
      else if Status in [$F0, $F7] then
      begin
        Running := 0;
        var N := VLQ;
        if N > Finish - P then
          raise EArgumentException.Create('Truncated MIDI SysEx');
        // Universal GM/GM2 reset and common GS/XG resets initialize channels.
        var GMReset := (N >= 5) and (Data[P] = $7E) and (Data[P + 2] = 9) and (Data[P + 3] in [1, 3]);
        var GSReset := (N >= 9) and (Data[P] = $41) and (Data[P + 2] = $42) and
          (Data[P + 3] = $12) and (Data[P + 4] = $40) and (Data[P + 5] = 0) and (Data[P + 6] = $7F) and (Data[P + 7] = 0);
        var XGReset := (N >= 8) and (Data[P] = $43) and (Data[P + 2] = $4C) and
          (Data[P + 3] = 0) and (Data[P + 4] = 0) and (Data[P + 5] = $7E) and (Data[P + 6] = 0);
        if GMReset or GSReset or XGReset then
        begin
          E.Status := $FF;
          Add(E);
        end;
        Inc(P, N);
      end
      else
        raise EArgumentException.Create('Unsupported system status in MIDI file');
    end;
    // Complete chunks without EOT occur in legacy exports; chunk bounds
    // still require every event and VLQ to be complete.
    EndTicks[Index] := Tick;
  end;

  procedure FinishSequence(Index: Integer; EndTick: Int64; const Title: string);
  begin
    Events.Sort(TComparer<TMidiEvent>.Construct(
      function(const A, B: TMidiEvent): Integer
      begin
        if A.Tick < B.Tick then
          Exit(-1);
        if A.Tick > B.Tick then
          Exit(1);
        Result := CompareValue(A.Order, B.Order);
      end));
    var Tick := Int64(0);
    var Frame := Int64(0);
    var Remainder := Int64(0);
    var Tempo := 500000;
    var Denominator := Int64(Division) * 1000000;
    var Numerator := Int64(Tempo) * 44100;
    if Division and $8000 <> 0 then
    begin
      var FPS := 256 - (Division shr 8);
      var TicksPerFrame := Division and 255;
      if not (FPS in [24, 25, 29, 30]) or (TicksPerFrame = 0) then
        raise EArgumentException.Create('Invalid MIDI SMPTE division');
      if FPS = 29 then
      begin
        Numerator := Int64(44100) * 1001;
        Denominator := Int64(30000) * TicksPerFrame;
      end
      else
      begin
        Numerator := 44100;
        Denominator := FPS * TicksPerFrame;
      end;
    end;
    for var I := 0 to Events.Count do
    begin
      var NextTick := EndTick;
      if I < Events.Count then
        NextTick := Events[I].Tick;
      var Delta := NextTick - Tick;
      // Bound before multiplication; at most 24 hours of audio per sequence.
      if (Delta < 0) or (Delta > (High(Int64) - Remainder) div Numerator) then
        raise EArgumentException.Create('MIDI timestamp exceeds limits');
      var N := Delta * Numerator + Remainder;
      Inc(Frame, N div Denominator);
      Remainder := N mod Denominator;
      Tick := NextTick;
      if Frame > Int64(44100) * 86400 then
        raise EArgumentException.Create('MIDI exceeds 24 hours');
      if I < Events.Count then
      begin
        var E := Events[I];
        E.Frame := Frame;
        Events[I] := E;
        if (E.Tempo <> 0) and (Division and $8000 = 0) then
          Numerator := Int64(E.Tempo) * 44100;
      end;
    end;
    FTracks[Index].Events := Events.ToArray;
    // A fixed two-second release tail keeps reported duration, EOF and export consistent.
    FTracks[Index].Frames := Frame + 88200;
    FTracks[Index].Title := Title;
    Events.Clear;
  end;

begin
  inherited Create;
  Data := Input;
  RequireBytes(Data, 0, 12);
  if (Tag(0) = 'RIFF') and (Tag(8) = 'RMID') then
  begin
    var EndPos := Int64(LE32(Data, 4)) + 8;
    if EndPos <> Length(Data) then
      raise EArgumentException.Create('Invalid RIFF MIDI length');
    var P := 12;
    var Found := False;
    while P < EndPos do
    begin
      RequireBytes(Data, P, 8);
      var N := LE32(Data, P + 4);
      if N > Cardinal(Length(Data) - P - 8) then
        raise EArgumentException.Create('Truncated RIFF MIDI chunk');
      if Tag(P) = 'data' then
      begin
        Data := Copy(Data, P + 8, Integer(N));
        Found := True;
        Break;
      end;
      Inc(P, 8 + Integer(N) + Integer(N and 1));
    end;
    if not Found then
      raise EArgumentException.Create('RIFF MIDI has no data chunk');
  end;
  if Tag(0) <> 'MThd' then
    raise EArgumentException.Create('Invalid MIDI header');
  var HeaderSize := BE32(4);
  if (HeaderSize < 6) or (HeaderSize > Cardinal(Length(Data) - 8)) then
    raise EArgumentException.Create('Invalid MIDI header size');
  FormatNumber := BE16(8);
  TrackCount := BE16(10);
  Division := BE16(12);
  if (FormatNumber > 2) or (TrackCount < 1) or (TrackCount > 256) or
    ((FormatNumber = 0) and (TrackCount <> 1)) or (Division = 0) then
    raise EArgumentException.Create('Unsupported MIDI format, track count or division');
  FInfo.FormatName := 'MIDI';
  FInfo.SampleRate := 44100;
  FInfo.Channels := 2;
  if FormatNumber = 2 then
    FInfo.TrackCount := TrackCount
  else
    FInfo.TrackCount := 1;
  SetLength(FTracks, FInfo.TrackCount);
  SetLength(EndTicks, TrackCount);
  SetLength(Names, TrackCount);
  Events := TList<TMidiEvent>.Create;
  Counter := 0;
  try
    var P := 8 + Integer(HeaderSize);
    for var I := 0 to TrackCount - 1 do
    begin
      if Tag(P) <> 'MTrk' then
        raise EArgumentException.Create('Missing MIDI track chunk');
      var N := BE32(P + 4);
      Inc(P, 8);
      if N > Cardinal(Length(Data) - P) then
        raise EArgumentException.Create('Truncated MIDI track');
      ParseTrack(P, P + Integer(N), I);
      Inc(P, Integer(N));
      if FormatNumber = 2 then
        FinishSequence(I, EndTicks[I], Names[I]);
    end;
    // Ignore exporter footers after the declared track chunks.
    if FormatNumber <> 2 then
    begin
      var EndTick := Int64(0);
      for var T in EndTicks do
        EndTick := Max(EndTick, T);
      FinishSequence(0, EndTick, Names[0]);
    end;
  finally
    Events.Free;
  end;
  SetLength(FInfo.TrackNames, FInfo.TrackCount);
  SetLength(FInfo.TrackDurations, FInfo.TrackCount);
  for Sequence := 0 to High(FTracks) do
  begin
    FInfo.TrackNames[Sequence] := FTracks[Sequence].Title;
    FInfo.TrackDurations[Sequence] := FTracks[Sequence].Frames / 44100;
  end;
  FInfo.Title := FTracks[0].Title;
  var Bank := GetBank;
  FInfo.Details := Format('SMF %d / %d MIDI tracks / %s', [FormatNumber, TrackCount, Bank.Name]);
  FSynth := TSoundFontSynth.Create(Bank);
  SelectTrack(0);
end;

destructor TMidiDecoder.Destroy;
begin
  FSynth.Free;
  inherited;
end;

function TMidiDecoder.GetInfo: TTuneInfo;
begin
  Result := FInfo;
end;

procedure TMidiDecoder.SelectTrack(Index: Integer);
begin
  if (Index < 0) or (Index >= Length(FTracks)) then
    raise EArgumentOutOfRangeException.Create('MIDI track');
  FTrack := Index;
  FEvent := 0;
  FPosition := 0;
  FReleased := False;
  FSynth.Reset;
end;

function TMidiDecoder.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
begin
  ValidateRender(Length(Samples), Frames, 2);
  Result := 0;
  var Track := FTracks[FTrack];
  while (Result < Frames) and (FPosition < Track.Frames) do
  begin
    while (FEvent < Length(Track.Events)) and (Track.Events[FEvent].Frame <= FPosition) do
    begin
      var E := Track.Events[FEvent];
      if E.Status = $FF then
        FSynth.Reset
      else if E.Status <> 0 then
        FSynth.Message(E.Status, E.A, E.B);
      Inc(FEvent);
    end;
    if not FReleased and (FPosition >= Track.Frames - 88200) then
    begin
      FSynth.ReleaseAll;
      FReleased := True;
    end;
    FSynth.Sample(Samples[Result * 2], Samples[Result * 2 + 1]);
    Inc(Result);
    Inc(FPosition);
  end;
end;

function OpenMidi(const Data: TBytes): ITuneDecoder;
begin
  Result := TMidiDecoder.Create(Data);
end;

initialization
  BankLock := TCriticalSection.Create;
  TTuneDecoders.RegisterFormat('.mid', 'Standard MIDI File / General MIDI', OpenMidi);
  TTuneDecoders.RegisterFormat('.midi', 'Standard MIDI File / General MIDI', OpenMidi);
  TTuneDecoders.RegisterFormat('.rmi', 'RIFF MIDI / General MIDI', OpenMidi);
  TTuneDecoders.RegisterFormat('.kar', 'MIDI karaoke (audio)', OpenMidi);

finalization
  CurrentBank := nil;
  BankLock.Free;

end.

