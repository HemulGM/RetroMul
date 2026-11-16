unit J2ME.Audio.State;

interface

uses
  System.SysUtils, Music.Decoder;

function OpenJ2MEDecoder(const Data: TBytes; const Extension: string): ITuneDecoder;

function RestoreJ2MEDecoder(const Data: TBytes; const Extension: string; Samples, SampleRate, Channels: Integer): ITuneDecoder;

implementation

uses
  System.Classes, System.Math, Music.Decoder.WAV, Music.Decoder.MIDI;

function OpenJ2MEDecoder(const Data: TBytes; const Extension: string): ITuneDecoder;
begin
  if SameText(Extension, '.wav') then
    Result := OpenWav(Data)
  else if SameText(Extension, '.mid') then
    Result := OpenMidi(Data)
  else
    raise EArgumentException.Create('Unsupported J2ME audio format: ' + Extension);
end;

function RestoreJ2MEDecoder(const Data: TBytes; const Extension: string; Samples, SampleRate, Channels: Integer): ITuneDecoder;
begin
  if not (Channels in [1, 2]) or (Samples < 0) or (Samples mod Channels <> 0) then
    raise EReadError.Create('Invalid snapshot decoder position');
  Result := OpenJ2MEDecoder(Data, Extension);
  var Info := Result.GetInfo;
  if (Info.SampleRate <> SampleRate) or (Info.Channels <> Channels) then
    raise EReadError.Create('Incompatible snapshot audio format');
  var Seeker: ITuneSeekDecoder;
  if Supports(Result, ITuneSeekDecoder, Seeker) then
  begin
    var Frame := Int64(Samples div Channels);
    if Seeker.SeekFrame(Frame,
      function: Boolean
      begin
        Result := TThread.CheckTerminated;
      end) <> Frame then
      raise EReadError.Create('Invalid snapshot decoder position');
    Exit;
  end;
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

