unit RM.Platforms.System18;

interface

uses
  Core.EmulatorRegistry;

type
  TSystem18Platform = class
  private
    class var
      FRegistered: Boolean;
    class function Recognize(Context: TCoreLoadContext): TCoreMatch; static;
  public
    class procedure RegisterPlatform; static;
  end;

implementation

uses
  System.Classes, Core.Emulation, Core.Platforms, Core.Snapshots, S18.RomSets,
  Core.Platforms.System18.Adapter, RM.Platforms.SegaArcade, SegaArcade.RomSets,
  Core.PlatformServices;

type
  TSystem18Settings = class(TSegaArcadeSettings)
  protected
    function DIPSection: string; override;
  end;

function TSystem18Settings.DIPSection: string;
begin
  Result := 'System18';
end;

class function TSystem18Platform.Recognize(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var RomSet: TSegaArcadeRomSet;
  if IdentifySystem18Rom(Context.Archive, Context.SourceName, RomSet) then
  begin
    Result := TCoreMatch.Create('System18',
      function: IEmulationCore
      begin
        Context.Stream.Position := 0;
        Result := TS18CoreAdapter.Create(Context.Stream, Context.Storage, Context.RomName);
      end);
    Result.Format.SystemId := 'system18';
  end;
end;

class procedure TSystem18Platform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  TPlatformRegistry.RegisterPlatform('system18', 'Sega System 18', 'System 18',
    'Sega', 'Sega System18 arcade', 'system18', ['system18', 'segas18'],
    [], 'System18', 'system18', 4);
  var Registration := TEmulationCoreRegistration.Create('System18', []);
  Registration.Add(TCoreLoadStage.Container, 20, Recognize);
  RegisterEmulationCore(Registration);
  RegisterSnapshotPolicy('system18', TSnapshotPolicy.Create(1));
  RegisterSegaArcadeServices('system18', TSystem18Settings);
  var Services := Default(TPlatformServices);
  Services.TerminalInput :=
    function(const Core: IEmulationCore): TTerminalInputPolicy
    begin
      Result.AllKeys := True;
      Result.ExitKey := $1B;
    end;
  RegisterPlatformServices('system18', Services);
  FRegistered := True;
end;

end.

