unit Wfx.Plugin.S3.tests;

interface

uses

  Wfx.Plugin.Intf,
  Wfx.Plugin.S3,
  Wfx.Plugin.S3.Path,
  DUnitX.TestFramework;

type
  [TestFixture]
  S3PluginFixture = class
    SUT : TS3Plugin;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test]
    procedure PluginNameNotEmpty;

    [Test]
    procedure InitDoesNotRaise;
  end;

  [TestFixture]
  S3PathFixture = class
  public
    // A folder whose name equals (or contains) the bucket name must not be
    // stripped away. Regression guard for the "stays in same directory" bug.
    [Test]
    procedure PrefixKeepsFolderNamedLikeBucket;
    [Test]
    procedure PrefixHandlesSubstringCollision;
    [Test]
    procedure BucketRootHasEmptyPrefix;
  end;

implementation

procedure S3PluginFixture.Setup;
begin
  SUT := TS3Plugin.Create;
end;

procedure S3PluginFixture.TearDown;
begin
  SUT.Free;
end;

procedure S3PluginFixture.PluginNameNotEmpty;
begin
  Assert.IsNotEmpty(SUT.GetPluginName);
end;

procedure S3PluginFixture.InitDoesNotRaise();
begin
  Assert.WillNotRaiseAny( SUT.Init );
end;

procedure S3PathFixture.PrefixKeepsFolderNamedLikeBucket;
var p: TS3TcPath;
begin
  p := TS3TcPath.Create('hydra-build');
  Assert.AreEqual('hydra-build/', p.GetPrefix('\hydra-build\hydra-build\'));
end;

procedure S3PathFixture.PrefixHandlesSubstringCollision;
var p: TS3TcPath;
begin
  p := TS3TcPath.Create('data');
  Assert.AreEqual('data-2024/', p.GetPrefix('\data\data-2024\'));
end;

procedure S3PathFixture.BucketRootHasEmptyPrefix;
var p: TS3TcPath;
begin
  p := TS3TcPath.Create('hydra-build');
  Assert.AreEqual('', p.GetPrefix('\hydra-build\'));
end;

initialization
  TDUnitX.RegisterTestFixture(S3PluginFixture);
  TDUnitX.RegisterTestFixture(S3PathFixture);

end.
