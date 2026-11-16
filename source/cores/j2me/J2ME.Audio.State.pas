unit J2ME.Audio.State;

interface

uses
  System.SysUtils, RetroTune.Decoder;

function RestoreJ2MEDecoder(const Data: TBytes; const Extension: string; Samples, SampleRate, Channels: Integer): ITuneDecoder;

implementation

uses
  System.Classes, System.Math;

function RestoreJ2MEDecoder(const Data: TBytes; const Extension: string; Samples, SampleRate, Channels: Integer): ITuneDecoder;
begin
  if not (Channels in [1, 2]) or (Samples < 0) or (Samples mod Channels <> 0) then
    raise EReadError.Create('Invalid snapshot decoder position');
  Result := TTuneDecoders.OpenData(Data, Extension);
  var Info := Result.GetInfo;
  if (Info.SampleRate <> SampleRate) or (Info.Channels <> Channels) then
    raise EReadError.Create('Incompatible snapshot audio format');
  var Remaining := Samples div Channels;
  var PCM: TArray<SmallInt>;
  SetLength(PCM, 4096 * Channels);
  while Remaining > 0 do
  begin
    var Requested := Min(4096, Remaining);
    var Read := Result.Render(PCM, Requested);
    if (Read <= 0) or (Read > Requested) then
      raise EReadError.Create('Invalid snapshot decoder position');
    Dec(Remaining, Read);
  end;
end;

end.

