unit RetroTune.FormatsForm;

interface

uses
  System.Classes, RetroTune.ReferenceForm;

type
  TTuneFormatsForm = class(TTuneReferenceForm)
  public
    constructor Create(AOwner: TComponent); override;
  end;

implementation

uses
  System.SysUtils, FMX.Types, RetroTune.Decoder;

constructor TTuneFormatsForm.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  var Formats := TTuneDecoders.SupportedFormats;
  SetHeading(Translate('Supported formats'),
    Format(Translate('%d extensions · Playback format reference'), [Length(Formats)]));
  FScroll.BeginUpdate;
  try
    AddSection(Translate('File extension / format'));
    for var Entry in Formats do
      AddField(Entry.Extension, Translate(Entry.Description));
  finally
    FScroll.EndUpdate;
  end;
end;

end.