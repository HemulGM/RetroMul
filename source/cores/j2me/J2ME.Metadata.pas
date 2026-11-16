unit J2ME.Metadata;

interface

uses
  System.SysUtils, System.Classes, Core.Storage, Core.RomMetadata, J2ME.Suite,
  J2ME.Screen, J2ME.Display;

function ReadJ2MEJAD(Input: TStream; const Storage: IStorage; const RomName: string; out Location, Error: string): TBytes;

function J2MERomMetadata(Suite: TJ2MESuite; const JarName, JarHash, JADLocation, JADError, Mode: string; const Screen: TJ2MEScreenDecision; const Display: TJ2MEDisplayPlan): IRomMetadata;

implementation

uses
  System.JSON, System.Generics.Collections, System.Generics.Defaults,
  Core.Archive.Container
  {$IFDEF ANDROID}, Core.Storage.Android{$ENDIF};

function ReadJ2MEJAD(Input: TStream; const Storage: IStorage; const RomName: string; out Location, Error: string): TBytes;
begin
  Result := nil;
  Location := '';
  Error := '';
  try
    TStorage.CheckReadCancelled;
    if Input is TArchiveImageStream then
    begin
      var Image := TArchiveImageStream(Input);
      var Name := ChangeFileExt(Image.MemberName, '.jad');
      if Image.Container <> nil then
      begin
        var I := Image.Container.FindName(Name);
        if I < 0 then
          Exit;
        Location := Image.Container.Entries[I].Name;
        if Image.Container.Entries[I].Size > 1024 * 1024 then
          raise EReadError.Create('JAD exceeds 1 MiB');
        Image.Container.Read(I, Result);
        Exit;
      end;
    end;
    var Name := ChangeFileExt(RomName, '.jad');
    if RomName.StartsWith('content://', True) then
    begin
      {$IFDEF ANDROID}
      // A lone document grant has no sibling authority. A configured tree grant
      // can locate the original document and its sibling without inventing URIs.
      var Folder := Storage.RomFolder('j2me');
      if not Folder.StartsWith('content://', True) then
        Exit;
      var Items := TAndroidStorage.Enumerate(Folder, True);
      var Relative := '';
      for var Item in Items do
      begin
        TStorage.CheckReadCancelled;
        if TAndroidStorage.SameDocument(Item.Location, RomName) then
          Relative := ChangeFileExt(Item.RelativePath, '.jad');
      end;
      if Relative = '' then
        Exit;
      Name := '';
      for var Item in Items do
        if SameText(Item.RelativePath, Relative) then
        begin
          if Name <> '' then
            raise EReadError.Create('Ambiguous JAD companion');
          Name := Item.Location;
        end;
      if Name = '' then
        Exit;
      {$ELSE}
      Exit;
      {$ENDIF}
    end
    else if not Storage.Exists(Name) then
    begin
      // Case-sensitive filesystems may contain GAME.JAD beside game.jar.
      var Match := '';
      for var Path in Storage.Files(ExtractFilePath(RomName)) do
      begin
        TStorage.CheckReadCancelled;
        if SameText(ExtractFileName(Path), ExtractFileName(Name)) then
        begin
          if Match <> '' then
            raise EReadError.Create('Ambiguous JAD companion');
          Match := Path;
        end;
      end;
      if Match = '' then
        Exit;
      Name := Match;
    end;
    Location := Name;
    var Stream := Storage.OpenRead(Name);
    try
      // Size can materialize an entire non-seekable document provider stream.
      // Read at most limit+1 bytes instead, checking cancellation between blocks.
      var Buffer := TMemoryStream.Create;
      try
        var Block: array[0..8191] of Byte;
        while True do
        begin
          TStorage.CheckReadCancelled;
          var Limit := Integer(1024 * 1024 + 1 - Buffer.Size);
          if Limit > SizeOf(Block) then
            Limit := SizeOf(Block);
          var N := Stream.Read(Block, Limit);
          if (N < 0) or (N > Limit) then
            raise EReadError.Create('Invalid JAD read count');
          if N = 0 then
            Break;
          Buffer.WriteBuffer(Block, N);
          if Buffer.Size > 1024 * 1024 then
            raise EReadError.Create('JAD exceeds 1 MiB');
        end;
        SetLength(Result, Buffer.Size);
        if Length(Result) > 0 then
          Move(Buffer.Memory^, Result[0], Length(Result));
      finally
        Buffer.Free;
      end;
    finally
      Stream.Free;
    end;
  except
    on E: EAbort do
      raise;
    on E: Exception do
    begin
      Error := E.Message;
      Result := nil;
    end;
  end;
end;

function J2MERomMetadata(Suite: TJ2MESuite; const JarName, JarHash, JADLocation, JADError, Mode: string; const Screen: TJ2MEScreenDecision; const Display: TJ2MEDisplayPlan): IRomMetadata;

  function Attributes(const Source: string): TJSONObject;
  begin
    Result := TJSONObject.Create;
    var Values := Suite.Properties(Source);
    TArray.Sort<TPair<string, string>>(Values, TComparer<TPair<string, string>>.Construct(
      function(const A, B: TPair<string, string>): Integer
      begin
        Result := CompareStr(A.Key, B.Key);
      end));
    for var Pair in Values do
      Result.AddPair(Pair.Key, Pair.Value);
  end;

begin
  var Document := TJSONObject.Create;
  try
    Document.AddPair('format', 'j2me');
    Document.AddPair('location', JarName);
    Document.AddPair('sha256', JarHash.ToLower);
    Document.AddPair('manifest', Attributes('manifest'));
    Document.AddPair('jad', Attributes('jad'));
    Document.AddPair('properties', Attributes(''));
    // Includes folded lines and named manifest sections that must not become
    // MIDlet application properties, while preserving the complete metadata.
    Document.AddPair('manifest_text', Suite.SourceText('manifest'));
    Document.AddPair('jad_text', Suite.SourceText('jad'));
    var Descriptor := TJSONObject.Create;
    Descriptor.AddPair('location', JADLocation);
    Descriptor.AddPair('error', JADError);
    Document.AddPair('descriptor', Descriptor);
    var MIDlets := TJSONArray.Create;
    for var I := 0 to Suite.MIDletCount - 1 do
    begin
      var M := Suite.MIDlet(I);
      var Item := TJSONObject.Create;
      Item.AddPair('name', M.Name);
      Item.AddPair('class', M.ClassName);
      Item.AddPair('icon', M.Icon);
      MIDlets.AddElement(Item);
    end;
    Document.AddPair('midlets', MIDlets);
    var Canvas := Screen.ToJSON;
    Canvas.AddPair('mode', Mode);
    Document.AddPair('screen', Canvas);
    Document.AddPair('display', Display.ToJSON);
    Result := TRomMetadata.Create(Document);
  finally
    Document.Free;
  end;
end;

end.

