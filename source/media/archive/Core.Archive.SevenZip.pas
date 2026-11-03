unit Core.Archive.SevenZip;

interface

uses
  System.Classes, Core.Storage, Core.Archive.Container;

function IsSevenZipArchive(Input: TStream): Boolean;

function OpenSevenZip(Input: TStream; const Storage: IStorage): IArchiveContainer;

implementation

uses
  System.SysUtils, Z7.Archive;

type
  TSevenZipContainer = class(TArchiveContainer)
  private
    FPacked: string;
    FArchive: TSevenZipArchive;
  protected
    procedure Extract(Index: Integer; Output: TStream); override;
  public
    constructor Create(Input: TStream; const Storage: IStorage);
    destructor Destroy; override;
  end;

function IsSevenZipArchive(Input: TStream): Boolean;
begin
  Result := ArchiveSignatureMatches(Input, [$37, $7A, $BC, $AF, $27, $1C]);
end;

constructor TSevenZipContainer.Create(Input: TStream; const Storage: IStorage);
begin
  inherited Create(Storage);
  FPacked := CacheArchiveInput(Input, FStorage,
    procedure(Path: string)
    begin TrackCacheFile(Path); end);
  FArchive := TSevenZipArchive.Create(FPacked,
    function: Boolean
    begin
      TStorage.CheckReadCancelled;
      Result := False;
    end, MaxArchiveEntries);
  for var E in FArchive.Entries do
  begin
    var Info := Default(TArchiveEntry);
    Info.Name := E.Name;
    Info.Size := E.Size;
    Info.CRC32 := E.CRC;
    Info.HasCRC := E.HasCRC;
    Info.IsDirectory := E.IsDirectory;
    AddEntry(Info);
  end;
end;

destructor TSevenZipContainer.Destroy;
begin
  FArchive.Free;
  inherited;
end;

procedure TSevenZipContainer.Extract(Index: Integer; Output: TStream);
begin
  FArchive.Extract(Index, Output);
end;

function OpenSevenZip(Input: TStream; const Storage: IStorage): IArchiveContainer;
begin
  Result := TSevenZipContainer.Create(Input, Storage);
end;

end.

