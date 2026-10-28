unit RM.Platforms.SNES.Callouts;

interface

uses
  RM.Settings.Callouts;

type
  TSNESDeviceCallouts = class(TPlatformDeviceCallouts)
  public
    class function Definitions(const Context: TDeviceCalloutContext): TArray<TDeviceCalloutDefinition>; override;
  end;

implementation

uses
  FMX.Types, Core.Emulation;

class function TSNESDeviceCallouts.Definitions(const Context: TDeviceCalloutContext): TArray<TDeviceCalloutDefinition>;
begin
  Result := inherited Definitions(Context);
  for var I := 0 to High(Result) do
    if Result[I].Button = Ord(TEmulatorButton.C) then
      Result[I].Left := True;
end;

end.
