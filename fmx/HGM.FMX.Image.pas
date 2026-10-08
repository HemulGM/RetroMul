unit HGM.FMX.Image;

interface

uses
  Core.Storage, System.Classes, System.Types, System.SysUtils, FMX.Forms,
  FMX.Graphics, FMX.Objects, FMX.Surfaces, System.Threading,
  System.Generics.Collections, System.Net.HttpClient;

type
  TCallbackObject = record
    RequestId: Int64;
    Owner: TComponent;
    Bitmap: TBitmap;
    Url: string;
    Task: ITask;
    OnDone: TProc<Boolean>;
    procedure Done(Success: Boolean);
  end;

  TObjectOwner = class(TComponent)
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
  end;

  TBitmapHelper = class helper for TBitmap
  private
    class var
      Pool: TThreadPool;
      FCallbackList: TThreadList<TCallbackObject>;
      FObjectOwner: TComponent;
      FClient: THTTPClient;
      FCachePath: string;
      FCacheExpire: Double;
      FNextRequestId: Int64;
  private
    class function UrlToCacheName(const Url: string): string;
    class procedure AddCallback(Callback: TCallbackObject);
    class function IsPending(RequestId: Int64): Boolean; static;
    class procedure Ready(RequestId: Int64; Surface: TBitmapSurface);
    class function Get(const URL: string): TMemoryStream; static;
    class function GetBitmap(const URL: string): TBitmapSurface; static;
    class function GetClient: THTTPClient; static;
    class procedure SetCachePath(const Value: string); static;
    class function FindCached(const Url: string; out Bitmap: TBitmapSurface): Boolean; static;
    class procedure AddCache(const Url: string; Bitmap: TBitmapSurface);
    class procedure AddCacheFileName(const FileName: string; Bitmap: TBitmapSurface);
    class function FindCachedFileName(const FileName: string; out Bitmap: TBitmapSurface): Boolean; static;
    class procedure SetCacheExpire(const Value: Double); static;
    class function GetBitmapFromFile(const FileName: string; const AFitWidth, AFitHeight: Single; const Storage: IStorage = nil): TBitmapSurface; static;
  public
    class procedure RemoveCallback(const AOwner: TComponent);
    class procedure CancelAll;
    procedure LoadFromUrl(const Url: string; UseCache: Boolean = True);
    procedure LoadFromUrlAsync(AOwner: TComponent; const Url: string; Cache: Boolean = True; OnDone: TProc<Boolean> = nil); overload;
    // Cache first check
    procedure LoadFromUrlAsyncCF(AOwner: TComponent; const Url: string; Cache: Boolean = True; OnDone: TProc<Boolean> = nil); overload;
    procedure LoadFromUrlAsyncCF(AOwner: TComponent; const Url, CachedFileName: string; OnDone: TProc<Boolean> = nil); overload;
    procedure LoadFromFileAsync(AOwner: TComponent; const FileName: string; OnDone: TProc<Boolean> = nil); overload;
    procedure LoadFromFileAsync(AOwner: TComponent; const FileName: string; const AFitWidth, AFitHeight: Single; OnDone: TProc<Boolean> = nil; const Storage: IStorage = nil); overload;
    procedure LoadFromResource(ResName: string); overload;
    procedure LoadFromResource(Instanse: NativeUInt; ResName: string); overload;
    procedure SaveToStream(Stream: TStream; const Ext: string); overload;
    procedure SaveToFile(const AFileName: string; const Ext: string); overload;
    class function CreateFromUrl(const Url: string; UseCache: Boolean = True): TBitmap;
    class function CreateFromResource(ResName: string; Url: string = ''): TBitmap;
    class property Client: THTTPClient read GetClient;
    class property CachePath: string read FCachePath write SetCachePath;
    class property CacheExpire: Double read FCacheExpire write SetCacheExpire;
  end;

implementation

uses
  FMX.Types, FMX.Consts, System.Hash, System.IOUtils, System.SyncObjs,
  System.Math;

{ TBitmapHelper }

class procedure TBitmapHelper.AddCallback(Callback: TCallbackObject);
begin
  Callback.Owner.FreeNotification(FObjectOwner);
  FCallbackList.Add(Callback);
end;

class function TBitmapHelper.IsPending(RequestId: Int64): Boolean;
begin
  Result := False;
  var List := FCallbackList.LockList;
  try
    for var Item in List do
      if Item.RequestId = RequestId then
        Exit(True);
  finally
    FCallbackList.UnlockList;
  end;
end;

class procedure TBitmapHelper.CancelAll;
begin
  var List := FCallbackList.LockList;
  try
    for var i := List.Count - 1 downto 0 do
      List[i].Task.Cancel;
    List.Clear;
  finally
    FCallbackList.UnlockList;
  end;
end;

class function TBitmapHelper.CreateFromResource(ResName, Url: string): TBitmap;
begin
  Result := TBitmap.Create;
  Result.LoadFromResource(ResName);
end;

class function TBitmapHelper.CreateFromUrl(const Url: string; UseCache: Boolean): TBitmap;
begin
  Result := TBitmap.Create;
  Result.LoadFromUrl(Url, False);
end;

procedure TBitmapHelper.LoadFromResource(ResName: string);
begin
  LoadFromResource(HInstance, ResName);
end;

procedure TBitmapHelper.LoadFromFileAsync(AOwner: TComponent; const FileName: string; OnDone: TProc<Boolean>);
begin
  LoadFromFileAsync(AOwner, FileName, 0, 0, OnDone);
end;

procedure TBitmapHelper.LoadFromFileAsync(AOwner: TComponent; const FileName: string; const AFitWidth, AFitHeight: Single; OnDone: TProc<Boolean>; const Storage: IStorage);
begin
  if AOwner = nil then
    raise Exception.Create('You must specify an owner (responsible) who will ensure that the Bitmap is not destroyed before the owner');
  var RequestId := TInterlocked.Increment(FNextRequestId);
  var Callback: TCallbackObject;
  Callback.RequestId := RequestId;
  Callback.Owner := AOwner;
  Callback.Bitmap := Self;
  Callback.Url := FileName;
  Callback.OnDone := OnDone;
  Callback.Task := TTask.Create(
    procedure
    begin
      try
        if not IsPending(RequestId) then
          Exit;
        var Mem := GetBitmapFromFile(FileName, AFitWidth, AFitHeight, Storage);
        if not IsPending(RequestId) then
        begin
          Mem.Free;
          Exit;
        end;
        TThread.ForceQueue(nil,
          procedure
          begin
            Ready(RequestId, Mem);
          end);
      except
        TThread.ForceQueue(nil,
          procedure
          begin
            Ready(RequestId, nil);
          end);
      end;
    end, Pool);
  AddCallback(Callback);
  Callback.Task.Start;
end;

procedure TBitmapHelper.LoadFromResource(Instanse: NativeUInt; ResName: string);
var
  Mem: TResourceStream;
begin
  Mem := TResourceStream.Create(Instanse, ResName, RT_RCDATA);
  try
    Mem.Position := 0;
    Self.LoadFromStream(Mem);
  finally
    Mem.Free;
  end;
end;

procedure TBitmapHelper.LoadFromUrl(const Url: string; UseCache: Boolean);
var
  Mem: TMemoryStream;
begin
  Mem := Get(Url);
  try
    Mem.Position := 0;
    Self.LoadFromStream(Mem);
  finally
    Mem.Free;
  end;
end;

class function TBitmapHelper.Get(const URL: string): TMemoryStream;
begin
  if URL.IsEmpty then
    raise Exception.Create('Empty URL');
  Result := TMemoryStream.Create;
  try
    if (GetClient.Get(URL, Result).StatusCode = 200) and (Result.Size > 0) then
      Result.Position := 0
    else
    begin
      Result.Free;
      Result := nil;
    end;
  except
    Result.Free;
    Result := nil;
  end;
end;

class function TBitmapHelper.GetBitmap(const URL: string): TBitmapSurface;
begin
  Result := TBitmapSurface.Create;
  try
    var Mem := Get(URL);
    if Assigned(Mem) then
    try
      if not TBitmapCodecManager.LoadFromStream(Mem, Result) then
        raise Exception.Create('Unable to decode image: ' + URL);
    finally
      Mem.Free;
    end
    else
    begin
      Result.Free;
      Result := nil;
    end;
  except
    Result.Free;
    raise;
  end;
end;

class function TBitmapHelper.GetBitmapFromFile(const FileName: string; const AFitWidth, AFitHeight: Single; const Storage: IStorage): TBitmapSurface;
begin
  // Workers decode and resize CPU pixels only. TBitmap handles and Canvas use
  // the shared FMX message manager and must be created/destroyed on the UI thread.
  Result := TBitmapSurface.Create;
  try
    var Source := Storage;
    if Source = nil then
      Source := TStorage.Default;
    var Stream := Source.OpenRead(FileName);
    try
      if not TBitmapCodecManager.LoadFromStream(Stream, Result) or
        (Result.Width < 1) or (Result.Height < 1) then
        raise Exception.Create('Unable to decode image: ' + FileName);
    finally
      Stream.Free;
    end;
    if (AFitWidth > 0) and (AFitHeight > 0) then
    begin
      var Fit := TRectF.Create(0, 0, Result.Width, Result.Height);
      Fit.Fit(TRectF.Create(0, 0, AFitWidth, AFitHeight));
      var Width := Trunc(Fit.Width);
      var Height := Trunc(Fit.Height);
      if Width < 1 then
        Width := 1;
      if Height < 1 then
        Height := 1;
      var Thumbnail := TBitmapSurface.Create;
      try
        if (Width = 1) or (Height = 1) or (Result.Width = 1) or (Result.Height = 1) then
        begin
          Thumbnail.SetSize(Width, Height, Result.PixelFormat);
          for var Y := 0 to Height - 1 do
            for var X := 0 to Width - 1 do
              Thumbnail.Pixels[X, Y] := Result.Pixels[Min(Result.Width - 1, X * Result.Width div Width),
                  Min(Result.Height - 1, Y * Result.Height div Height)];
        end
        else
          Thumbnail.StretchFrom(Result, Width, Height);
      except
        Thumbnail.Free;
        raise;
      end;
      Result.Free;
      Result := Thumbnail;
    end;
  except
    Result.Free;
    raise;
  end;
end;

class function TBitmapHelper.GetClient: THTTPClient;
begin
  if not Assigned(FClient) then
  begin
    FClient := THTTPClient.Create;
    FClient.HandleRedirects := True;
  end;
  Result := FClient;
end;

class function TBitmapHelper.FindCached(const Url: string; out Bitmap: TBitmapSurface): Boolean;
begin
  Result := False;
  Bitmap := nil;
  var FileName := TPath.Combine(FCachePath, UrlToCacheName(Url));
  var Storage := TStorage.Default;
  if Storage.Exists(FileName) then
  begin
    if CacheExpire > 0 then
    begin
      if Storage.ModifiedTime(FileName) + CacheExpire < Now then
      begin
        try
          Storage.Delete(FileName);
        except
          // не смог удалить файл
        end;
        Exit;
      end;
    end;
    try
      Bitmap := GetBitmapFromFile(FileName, 150, 150, Storage);
      Result := True;
    except
      Bitmap.Free;
      Bitmap := nil;
    end;
  end;
end;

class function TBitmapHelper.FindCachedFileName(const FileName: string; out Bitmap: TBitmapSurface): Boolean;
begin
  Result := False;
  Bitmap := nil;
  var FilePath := TPath.Combine(FCachePath, FileName);
  var Storage := TStorage.Default;
  if Storage.Exists(FilePath) then
  try
    Bitmap := GetBitmapFromFile(FilePath, 150, 150, Storage);
    Result := True;
  except
    Bitmap.Free;
    Bitmap := nil;
  end;
end;

class procedure TBitmapHelper.AddCacheFileName(const FileName: string; Bitmap: TBitmapSurface);
begin
  var FilePath := TPath.Combine(FCachePath, FileName);
  try
    TStorage.Default.Delete(FilePath);
  except
    Exit;
  end;
  try
    var Stream := TMemoryStream.Create;
    try
      if TBitmapCodecManager.SaveToStream(Stream, Bitmap, '.png') then
      begin
        Stream.Position := 0;
        TStorage.Default.WriteAtomic(FilePath, Stream);
      end;
    finally
      Stream.Free;
    end;
  except
    //
  end;
end;

class procedure TBitmapHelper.AddCache(const Url: string; Bitmap: TBitmapSurface);
begin
  var FileName := TPath.Combine(FCachePath, UrlToCacheName(Url));
  try
    TStorage.Default.Delete(FileName);
  except
    Exit;
  end;
  try
    var Stream := TMemoryStream.Create;
    try
      if TBitmapCodecManager.SaveToStream(Stream, Bitmap, '.png') then
      begin
        Stream.Position := 0;
        TStorage.Default.WriteAtomic(FileName, Stream);
      end;
    finally
      Stream.Free;
    end;
  except
    //
  end;
end;

procedure TBitmapHelper.LoadFromUrlAsync(AOwner: TComponent; const Url: string; Cache: Boolean; OnDone: TProc<Boolean>);
begin
  if Url.IsEmpty then
  begin
    if Assigned(OnDone) then
      OnDone(False);
    Exit;
  end;
  if AOwner = nil then
    raise Exception.Create('You must specify an owner (responsible) who will ensure that the Bitmap is not destroyed before the owner');
  var RequestId := TInterlocked.Increment(FNextRequestId);
  var Callback: TCallbackObject;
  Callback.RequestId := RequestId;
  Callback.Owner := AOwner;
  Callback.Bitmap := Self;
  Callback.Url := Url;
  Callback.OnDone := OnDone;
  Callback.Task := TTask.Create(
    procedure
    begin
      try
        if not IsPending(RequestId) then
          Exit;
        var Mem: TBitmapSurface;
        if not FindCached(Url, Mem) then
        begin
          Mem := GetBitmap(Url);
          if Cache and Assigned(Mem) then
            AddCache(Url, Mem);
        end;
        if not IsPending(RequestId) then
        begin
          Mem.Free;
          Exit;
        end;
        TThread.ForceQueue(nil,
          procedure
          begin
            Ready(RequestId, Mem);
          end);
      except
        TThread.ForceQueue(nil,
          procedure
          begin
            Ready(RequestId, nil);
          end);
      end;
    end, Pool);
  AddCallback(Callback);
  Callback.Task.Start;
end;

procedure TBitmapHelper.LoadFromUrlAsyncCF(AOwner: TComponent; const Url, CachedFileName: string; OnDone: TProc<Boolean>);
begin
  var Stream: TBitmapSurface;
  if FindCachedFileName(CachedFileName, Stream) then
  try
    try
      //LoadFromStream(Stream);
      Assign(Stream);
      if Assigned(OnDone) then
        OnDone(True);
      Exit;
    except
      // reload
    end;
  finally
    Stream.Free;
  end;
  if AOwner = nil then
    raise Exception.Create('You must specify an owner (responsible) who will ensure that the Bitmap is not destroyed before the owner');
  var RequestId := TInterlocked.Increment(FNextRequestId);
  var Callback: TCallbackObject;
  Callback.RequestId := RequestId;
  Callback.Owner := AOwner;
  Callback.Bitmap := Self;
  Callback.Url := Url;
  Callback.OnDone := OnDone;
  Callback.Task := TTask.Create(
    procedure
    begin
      try
        if not IsPending(RequestId) then
          Exit;
        var Mem := GetBitmap(Url);
        if Assigned(Mem) then
          AddCacheFileName(CachedFileName, Mem);
        if not IsPending(RequestId) then
        begin
          Mem.Free;
          Exit;
        end;
        TThread.ForceQueue(nil,
          procedure
          begin
            Ready(RequestId, Mem);
          end);
      except
        TThread.ForceQueue(nil,
          procedure
          begin
            Ready(RequestId, nil);
          end);
      end;
    end, Pool);
  AddCallback(Callback);
  Callback.Task.Start;
end;

procedure TBitmapHelper.LoadFromUrlAsyncCF(AOwner: TComponent; const Url: string; Cache: Boolean; OnDone: TProc<Boolean>);
begin
  if Url.IsEmpty then
  begin
    if Assigned(OnDone) then
      OnDone(False);
    Exit;
  end;
  var Stream: TBitmapSurface;
  if FindCached(Url, Stream) then
  try
    //Stream.Position := 0;
    try
      //LoadFromStream(Stream);
      Assign(Stream);
      if Assigned(OnDone) then
        OnDone(True);
    except
      if Assigned(OnDone) then
        OnDone(False);
    end;
    Exit;
  finally
    Stream.Free;
  end;
  LoadFromUrlAsync(AOwner, Url, Cache, OnDone);
end;

class procedure TBitmapHelper.Ready(RequestId: Int64; Surface: TBitmapSurface);
begin
  try
    var Found := False;
    var Item: TCallbackObject;
    var List := FCallbackList.LockList;
    try
      for var i := List.Count - 1 downto 0 do
      begin
        if List[i].RequestId <> RequestId then
          Continue;
        Item := List[i];
        Found := True;
        // Remove before Assign/OnDone: either can trigger another request or
        // destroy owners. Never iterate a list while delivering notifications.
        List.Delete(i);
        Break;
      end;
    finally
      FCallbackList.UnlockList;
    end;
    if not Found then
      Exit; // Cancelled or destroyed owner; discard stale pixels.
    var Success := False;
    try
      if Surface <> nil then
      begin
        Item.Bitmap.Assign(Surface);
        Success := True;
      end;
    except
      Success := False;
    end;
    Item.Done(Success);
  finally
    Surface.Free;
  end;
end;

class procedure TBitmapHelper.RemoveCallback(const AOwner: TComponent);
begin
  var List := FCallbackList.LockList;
  try
    for var i := List.Count - 1 downto 0 do
      if List[i].Owner = AOwner then
      begin
        List[i].Task.Cancel;
        List.Delete(i);
      end;
  finally
    FCallbackList.UnlockList;
  end;
end;

procedure TBitmapHelper.SaveToFile(const AFileName, Ext: string);
var
  Stream: TMemoryStream;
begin
  Stream := TMemoryStream.Create;
  try
    SaveToStream(Stream, Ext);
    TStorage.Default.WriteAtomic(AFileName, Stream);
  finally
    Stream.Free;
  end;
end;

procedure TBitmapHelper.SaveToStream(Stream: TStream; const Ext: string);
var
  Surf: TBitmapSurface;
begin
  TMonitor.Enter(Self);
  try
    Surf := TBitmapSurface.Create;
    try
      Surf.Assign(Self);
      if not TBitmapCodecManager.SaveToStream(Stream, Surf, Ext) then
        raise EBitmapSavingFailed.Create(SBitmapSavingFailed);
    finally
      Surf.Free;
    end;
  finally
    TMonitor.Exit(Self);
  end;
end;

class procedure TBitmapHelper.SetCacheExpire(const Value: Double);
begin
  FCacheExpire := Value;
end;

class procedure TBitmapHelper.SetCachePath(const Value: string);
begin
  FCachePath := Value;
end;

class function TBitmapHelper.UrlToCacheName(const Url: string): string;
begin
  Result := THashMD5.GetHashString(Url);
end;

{ TObjectOwner }

procedure TObjectOwner.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited;
  if Operation <> TOperation.opRemove then
    Exit;
  var List := TBitmap.FCallbackList.LockList;
  try
    for var i := List.Count - 1 downto 0 do
      if List[i].Owner = AComponent then
      begin
        List[i].Task.Cancel;
        List.Delete(i);
      end;
  finally
    TBitmap.FCallbackList.UnlockList;
  end;
end;

{ TCallbackObject }

procedure TCallbackObject.Done(Success: Boolean);
begin
  if Assigned(OnDone) then
  try
    OnDone(Success);
  except
    //
  end;
end;

initialization
  TBitmap.CacheExpire := 0;
  TBitmap.Pool := TThreadPool.Create;
  TBitmap.FCallbackList := TThreadList<TCallbackObject>.Create;
  TBitmap.FObjectOwner := TObjectOwner.Create(nil);
  TBitmap.FClient := nil;

finalization
  TBitmap.Pool.Free;
  TBitmap.FCallbackList.Free;
  TBitmap.FObjectOwner.Free;
  TBitmap.FClient.Free;

end.

