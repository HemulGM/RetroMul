unit NES.Audio.Recordings;

interface

uses
  Core.Storage;

type
  TNesSpeechRecording = record
    Rate: Integer;
    Samples: TArray<SmallInt>;
  end;

  TNesSpeechRecordings = array[0..63] of TNesSpeechRecording;

function LoadSpeechRecordings(const Storage: IStorage; const RomName, Pack: string; TrackCount: Integer; var Recordings: TNesSpeechRecordings): Boolean;

implementation

uses
  System.Classes, System.SysUtils, System.IOUtils, System.Math, Audio.Format.WAV;

function LoadSpeechRecordings(const Storage: IStorage; const RomName, Pack: string; TrackCount: Integer; var Recordings: TNesSpeechRecordings): Boolean;
begin
  Result := False;
  var RomFolder := ExtractFilePath(RomName.Replace('/', PathDelim));
  var BiosFolder := TPath.Combine(Storage.Root, 'bios');
  for var Folder in TArray<string>.Create(RomFolder, BiosFolder) do
  begin
    if Folder = '' then
      Continue;
    var SamplesFolder := TPath.Combine(Folder, Pack);
    if not Storage.FolderExists(SamplesFolder) then
      Continue;
    for var Track := 0 to TrackCount - 1 do
    begin
      if Length(Recordings[Track].Samples) <> 0 then
        Continue;
      var Path := TPath.Combine(SamplesFolder, Format('%.2d.wav', [Track]));
      if not Storage.Exists(Path) then
        Continue;
      try
        var Input := Storage.OpenRead(Path);
        try
          var Decoder := TWavDecoder.Create(ReadRomData(Input, 2 * 1024 * 1024));
          try
            var Info := Decoder.GetInfo;
            if (Info.Channels <> 1) or (Info.SampleRate < 4000) or (Info.SampleRate > 96000) or
              (Info.TrackDurations[0] > 10.0) then
              Continue;
            var FrameCount := Round(Info.TrackDurations[0] * Info.SampleRate);
            SetLength(Recordings[Track].Samples, FrameCount);
            var Position := 0;
            var Buffer: array[0..4095] of SmallInt;
            while Position < FrameCount do
            begin
              var Count := Decoder.Render(Buffer, Min(Length(Buffer), FrameCount - Position));
              if Count = 0 then
                Break;
              Move(Buffer[0], Recordings[Track].Samples[Position], Count * SizeOf(SmallInt));
              Inc(Position, Count);
            end;
            SetLength(Recordings[Track].Samples, Position);
            Recordings[Track].Rate := Info.SampleRate;
            Result := Result or (Position <> 0);
          finally
            Decoder.Free;
          end;
        finally
          Input.Free;
        end;
      except
        on E: EArgumentException do
          Recordings[Track] := Default(TNesSpeechRecording);
        on E: EStreamError do
          Recordings[Track] := Default(TNesSpeechRecording);
      end;
    end;
  end;
end;

end.

