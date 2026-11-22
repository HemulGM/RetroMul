unit NES.StudyBox.Media;

interface

uses
  System.Classes, System.SysUtils, Audio.Types, NES.Types;

const
  STUDY_BOX_SIGNATURE: AnsiString = 'STBX';
  STUDY_BOX_MAX_SIZE = 256 * 1024 * 1024;
  STUDY_BOX_BIOS_SIZE = $40000;
  STUDY_BOX_BIOS_FILE = 'StudyBox.bin';

type
  TStudyBoxPage = record
    LeadIn, AudioStart: Cardinal;
    Data: TBytes;
  end;

  TStudyBoxMedia = record
    Pages: TArray<TStudyBoxPage>;
    Audio: IAudioSource;
    SampleRate, AudioFrames: Integer;
    Identity: string;
    class function Load(Stream: TStream; const Bios: TByteArray): TStudyBoxMedia; static;
  end;

implementation

uses
  System.Generics.Collections, System.Hash, Audio.Format.WAV;

class function TStudyBoxMedia.Load(Stream: TStream; const Bios: TByteArray): TStudyBoxMedia;
const
  MaxPageCount = 65536;
type
  TTag = array[0..3] of AnsiChar;
var
  Tag: TTag;
  Pages: TList<TStudyBoxPage>;
  Hash: THashSHA1;
  AudioData: TBytes;

  procedure Read(var Data; Count: Integer);
  begin
    if Count > Stream.Size - Stream.Position then
      raise ENesException.Create('Truncated StudyBox tape');
    Stream.ReadBuffer(Data, Count);
    Hash.Update(Data, Count);
  end;

  function ReadCardinal: Cardinal;
  begin
    Read(Result, SizeOf(Result));
  end;

  function ReadBytes(Count: Integer): TBytes;
  begin
    SetLength(Result, Count);
    Read(Result[0], Count);
  end;

begin
  Result := Default(TStudyBoxMedia);
  if (Stream.Size < 12) or (Stream.Size > STUDY_BOX_MAX_SIZE) then
    raise ENesException.Create('Invalid StudyBox tape size');

  if Length(Bios) <> STUDY_BOX_BIOS_SIZE then
    raise ENesException.Create('Invalid StudyBox BIOS size');
  Hash := THashSHA1.Create;
  Hash.Update(Bios[0], Length(Bios));
  Read(Tag, SizeOf(Tag));
  if not CompareMem(@Tag, PAnsiChar(STUDY_BOX_SIGNATURE), SizeOf(Tag)) or
    (ReadCardinal <> 4) or (ReadCardinal <> $100) then
    raise ENesException.Create('Unsupported StudyBox tape header');

  Pages := TList<TStudyBoxPage>.Create;
  try
    while Stream.Position < Stream.Size do
    begin
      Read(Tag, SizeOf(Tag));
      var Size := ReadCardinal;
      if Int64(Size) > Stream.Size - Stream.Position then
        raise ENesException.Create('Truncated StudyBox chunk');
      if CompareMem(@Tag, PAnsiChar(AnsiString('PAGE')), SizeOf(Tag)) then
      begin
        if (Size < 14) or (Pages.Count = MaxPageCount) then
          raise ENesException.Create('Invalid StudyBox PAGE size');
        var Page: TStudyBoxPage;
        Page.LeadIn := ReadCardinal;
        Page.AudioStart := ReadCardinal;
        if Page.AudioStart < Page.LeadIn then
          raise ENesException.Create('Invalid StudyBox lead-in');
        if (Pages.Count > 0) and ((Page.LeadIn < Pages.Last.LeadIn) or
          (Page.AudioStart <= Pages.Last.AudioStart)) then
          raise ENesException.Create('StudyBox pages are out of order');
        Page.Data := ReadBytes(Integer(Size) - 8);
        Pages.Add(Page);
      end
      else if CompareMem(@Tag, PAnsiChar(AnsiString('AUDI')), SizeOf(Tag)) then
      begin
        if (Size <= 4) or (Int64(Size) <> Stream.Size - Stream.Position) then
          raise ENesException.Create('Invalid StudyBox AUDI chunk');
        if ReadCardinal <> 0 then
          raise ENesException.Create('StudyBox requires a WAV audio chunk');
        AudioData := ReadBytes(Integer(Size) - 4);
        var Decoder := TWavDecoder.Create(AudioData);
        Result.Audio := Decoder;
        var Info := Decoder.GetInfo;
        if (Info.Channels <> 1) or (Info.SampleRate <= 0) or
          (Info.SampleRate > 192000) or (Length(Info.TrackDurations) <> 1) then
          raise ENesException.Create('StudyBox audio must be mono WAV');
        Result.SampleRate := Info.SampleRate;
        Result.AudioFrames := Round(Info.TrackDurations[0] * Info.SampleRate);
        if (Result.AudioFrames <= 0) or
          ((Pages.Count > 0) and (Pages.Last.AudioStart >= Cardinal(Result.AudioFrames))) then
          raise ENesException.Create('StudyBox audio does not reach the last page');
      end
      else
        raise ENesException.Create('Unknown StudyBox tape chunk');
    end;
    if Pages.Count = 0 then
      raise ENesException.Create('StudyBox tape has no pages');
    if Result.Audio = nil then
      raise ENesException.Create('StudyBox tape has no audio');
    Result.Pages := Pages.ToArray;
    Result.Identity := LowerCase(Hash.HashAsString);
  finally
    Pages.Free;
  end;
end;

end.

