unit RetroTune.InfoForm;

interface

uses
  RetroTune.ReferenceForm, RetroTune.Decoder;

type
  TTuneInfoForm = class(TTuneReferenceForm)
  public
    procedure SetInfo(const Path: string; FileSize: Int64; const Info: TTuneInfo);
  end;

implementation

uses
  System.SysUtils, System.Types, FMX.Types;

procedure TTuneInfoForm.SetInfo(const Path: string; FileSize: Int64; const Info: TTuneInfo);
begin
  FScroll.BeginUpdate;
  try
    ClearContent;
    SetHeading(Translate('File information'), ExtractFileName(Path) + ' · ' + Info.FormatName);
    Caption := Format(Translate('Information — %s'), [ExtractFileName(Path)]);
    AddSection(Translate('File'));
    AddField(Translate('File'), ExtractFileName(Path));
    AddField(Translate('Full path'), Path);
    AddField(Translate('Size, bytes'), IntToStr(FileSize));
    AddSection(Translate('Metadata'));
    AddField(Translate('Title'), Info.Title);
    AddField(Translate('Artist / composer'), Info.Artist);
    AddField(Translate('Copyright'), Info.CopyrightText);
    AddSection(Translate('Audio'));
    AddField(Translate('Format'), Info.FormatName);
    AddField(Translate('Description'), Info.Details);
    AddField(Translate('Sample rate, Hz'), IntToStr(Info.SampleRate));
    AddField(Translate('Channels'), IntToStr(Info.Channels));
    AddSection(Translate('Tracks'));
    AddField(Translate('Track count'), IntToStr(Info.TrackCount));
    AddField(Translate('Default track'), IntToStr(Info.DefaultTrack + 1));
    for var I := 0 to Info.TrackCount - 1 do
    begin
      AddSection(Format(Translate('Track %d'), [I + 1]));
      if I < Length(Info.TrackNames) then
        AddField(Format(Translate('Track %d title'), [I + 1]), Info.TrackNames[I]);
      if (I < Length(Info.TrackDurations)) and (Info.TrackDurations[I] >= 0) then
        AddField(Format(Translate('Track %d duration, seconds'), [I + 1]), FloatToStr(Info.TrackDurations[I]))
      else
        AddField(Format(Translate('Track %d duration'), [I + 1]), Translate('Unknown'));
    end;
    if Length(Info.Metadata) > 0 then
    begin
      AddSection(Translate('Additional information'));
      for var Field in Info.Metadata do
        AddField(Field.Name, Field.Value);
    end;
    FScroll.ViewportPosition := PointF(0, 0);
  finally
    FScroll.EndUpdate;
  end;
end;

end.

