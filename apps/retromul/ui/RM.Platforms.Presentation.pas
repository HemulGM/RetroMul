unit RM.Platforms.Presentation;

interface

uses
  Core.Platforms;

{$SCOPEDENUMS ON}

type
  TPlatformPresentation = record
    SettingsPageId: string;
    IconData: string;
  end;

type
  TPresentationRegistrationListener = reference to procedure(const PlatformId: string);

// Registration uses canonical platform IDs and can precede core metadata.
procedure RegisterPlatformPresentation(const Id, SettingsPageId: string; const IconData: string);

function TryPlatformPresentation(const Id: string; out Value: TPlatformPresentation): Boolean;

function PlatformPresentation(const Id: string): TPlatformPresentation;

function AddPresentationRegistrationListener(const Listener: TPresentationRegistrationListener): Integer;

procedure RemovePresentationRegistrationListener(Token: Integer);

implementation

uses
  System.SysUtils, System.Generics.Collections, System.Generics.Defaults;

var
  Presentations: TDictionary<string, TPlatformPresentation>;
  Listeners: TDictionary<Integer, TPresentationRegistrationListener>;
  NextListener: Integer;

procedure RegisterPlatformPresentation(const Id, SettingsPageId: string; const IconData: string);
begin
  if (Id = '') or ((SettingsPageId.Trim = '') or SameText(SettingsPageId.Trim, 'main')) or (IconData = '') then
    raise EArgumentException.Create('Invalid platform presentation: ' + Id);
  var Info: TPlatformInfo;
  if TPlatformRegistry.Find(Id, Info) and not SameText(Id, Info.Id) then
    raise EArgumentException.Create('Register the canonical platform presentation: ' + Info.Id);
  if Presentations.ContainsKey(Id) then
    raise EArgumentException.Create('Duplicate platform presentation: ' + Id);
  var Value: TPlatformPresentation;
  Value.SettingsPageId := SettingsPageId.Trim.ToLower;
  Value.IconData := IconData;
  Presentations.Add(Id, Value);
  for var Listener in Listeners.Values.ToArray do
    Listener(Id);
end;

function TryPlatformPresentation(const Id: string; out Value: TPlatformPresentation): Boolean;
begin
  Value := Default(TPlatformPresentation);
  var Info: TPlatformInfo;
  Result := TPlatformRegistry.Find(Id, Info) and Presentations.TryGetValue(Info.Id, Value);
end;

function PlatformPresentation(const Id: string): TPlatformPresentation;
begin
  var Info := TPlatformRegistry.Require(Id);
  if not Presentations.TryGetValue(Info.Id, Result) then
    raise EArgumentException.Create('Unknown platform presentation');
end;

function AddPresentationRegistrationListener(const Listener: TPresentationRegistrationListener): Integer;
begin
  if not Assigned(Listener) then
    raise EArgumentNilException.Create('Listener');
  Inc(NextListener);
  Result := NextListener;
  Listeners.Add(Result, Listener);
end;

procedure RemovePresentationRegistrationListener(Token: Integer);
begin
  Listeners.Remove(Token);
end;

initialization
  Presentations := TDictionary<string, TPlatformPresentation>.Create(TIStringComparer.Ordinal);
  Listeners := TDictionary<Integer, TPresentationRegistrationListener>.Create;

finalization
  Listeners.Free;
  Presentations.Free;

end.

