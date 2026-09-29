unit NES.State;

interface

uses
  System.Classes;

type
  // Explicit field serialization: never persist object pointers or callbacks.
  // Bump the file version whenever the serialized field order/layout changes.
  TNesStateArchive = class
  private
    FStream: TStream;
    FLoading: Boolean;
  public
    constructor Create(Stream: TStream; Loading: Boolean);
    procedure Field(var Value; Size: Integer);
  end;

procedure ReplaceSnapshotFile(const Temporary, Destination: string);

implementation

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ELSE}
  Posix.Stdio,
  {$ENDIF}
  System.SysUtils;

constructor TNesStateArchive.Create(Stream: TStream; Loading: Boolean);
begin
  inherited Create;
  FStream := Stream;
  FLoading := Loading;
end;

procedure TNesStateArchive.Field(var Value; Size: Integer);
begin
  var StoredSize := Size;
  if FLoading then
  begin
    FStream.ReadBuffer(StoredSize, SizeOf(StoredSize));
    if (StoredSize <> Size) or (Size > FStream.Size - FStream.Position) then
      raise EReadError.Create('Incompatible or truncated snapshot');
    if Size > 0 then
      FStream.ReadBuffer(Value, Size);
  end
  else
  begin
    FStream.WriteBuffer(StoredSize, SizeOf(StoredSize));
    if Size > 0 then
      FStream.WriteBuffer(Value, Size);
  end;
end;

procedure ReplaceSnapshotFile(const Temporary, Destination: string);
begin
  {$IFDEF MSWINDOWS}
  if not MoveFileEx(PChar(Temporary), PChar(Destination), MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
    RaiseLastOSError;
  {$ELSE}
  var SourcePath := UTF8String(Temporary);
  var TargetPath := UTF8String(Destination);
  if Posix.Stdio.__rename(PAnsiChar(SourcePath), PAnsiChar(TargetPath)) <> 0 then
    RaiseLastOSError;
  {$ENDIF}
end;

end.

