unit RetroTune.SoundFontCatalog;

interface

type
  TStandardSoundFont = record
    ID, Name, Path: string;
  end;

function StandardSoundFonts(const ExecutableDirectory: string): TArray<TStandardSoundFont>;

function StandardSoundFontAvailable(const Path: string): Boolean;

implementation

uses
  System.SysUtils, System.IOUtils;

function StandardSoundFontAvailable(const Path: string): Boolean;
begin
  Result := TFile.Exists(Path);
end;

function StandardSoundFonts(const ExecutableDirectory: string): TArray<TStandardSoundFont>;
begin
  SetLength(Result, 3);
  Result[0].ID := 'generaluser';
  Result[0].Name := 'GeneralUser GS';
  Result[0].Path := TPath.Combine(TPath.Combine(ExecutableDirectory, 'sf2'), 'GeneralUser-GS.sf2');
  Result[1].ID := 'timgm6mb';
  Result[1].Name := 'TimGM6mb';
  Result[1].Path := TPath.Combine(TPath.Combine(ExecutableDirectory, 'sf2'), 'TimGM6mb.sf2');
  Result[2].ID := 'fluidr3';
  Result[2].Name := 'FluidR3 GM';
  Result[2].Path := TPath.Combine(TPath.Combine(ExecutableDirectory, 'sf2'), 'FluidR3_GM.sf2');
end;

end.

