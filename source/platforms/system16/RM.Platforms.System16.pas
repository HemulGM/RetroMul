unit RM.Platforms.System16;

interface

uses
  Core.EmulatorRegistry;

type
  TSystem16Platform = class
  private
    class var
      FRegistered: Boolean;
    class function Recognize(Context: TCoreLoadContext): TCoreMatch; static;
  public
    class procedure RegisterPlatform; static;
  end;

implementation

uses
  Core.PlatformServices, RA.Console, System.Classes, Core.Emulation,
  Core.Platforms, Core.Snapshots, S16.RomSets, Core.Platforms.System16.Adapter,
  RM.Platforms.SegaArcade;

type
  TSystem16Settings = class(TSegaArcadeSettings)
  protected
    function DIPSection: string; override;
  end;

function TSystem16Settings.DIPSection: string;
begin
  Result := 'System16';
end;

class function TSystem16Platform.Recognize(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var RomSet: TS16RomSet;
  if IdentifySystem16Rom(Context.Archive, Context.SourceName, RomSet) then
  begin
    Result := TCoreMatch.Create('System16',
      function: IEmulationCore
      begin
        Context.Stream.Position := 0;
        Result := TS16CoreAdapter.Create(Context.Stream, Context.Storage, Context.RomName);
      end);
    Result.Format.SystemId := 'system16';
    if RomSet.ArchiveProgramMatched then
      Result.AchievementSetName := RomSet.Name;
  end;
end;

class procedure TSystem16Platform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  TPlatformRegistry.RegisterPlatform('system16', 'Sega System 16', 'System 16',
    'Sega', 'Sega System16 System 16A 16B arcade', 'system16', ['system16', 'segas16'],
    [], 'System16', 'system16', 4);
  var Registration := TEmulationCoreRegistration.Create('System16', []);
  Registration.Add(TCoreLoadStage.Container, 20, Recognize);
  RegisterEmulationCore(Registration);
  RegisterSnapshotPolicy('system16', TSnapshotPolicy.Create(2));
  RegisterSegaArcadeServices('system16', TSystem16Settings);
  RegisterPlatformAchievementMedia('system16', RAConsoleArcade, ['.zip', '.7z']);
  FRegistered := True;
end;

end.

