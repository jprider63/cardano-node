{ config
, lib
, pkgs
, ... }:

with lib; with builtins;
let
  cfg = config.services.cardano-node;
  envConfig = cfg.environments.${cfg.environment};
  runtimeDir = i : if cfg.runtimeDir == null then cfg.stateDir i else "/run/${cfg.runtimeDir i}";
  oneShotStateDir = "/var/lib/cardano-node-all";
  mkScript = cfg:
    let baseConfig =
          recursiveUpdate
            (cfg.nodeConfig
             // (mapAttrs' (era: epoch:
               nameValuePair "Test${era}HardForkAtEpoch" epoch
             ) cfg.forceHardForks)
            // (optionalAttrs cfg.useNewTopology {
              EnableP2P = true;
              TargetNumberOfRootPeers = cfg.targetNumberOfRootPeers;
              TargetNumberOfKnownPeers = cfg.targetNumberOfKnownPeers;
              TargetNumberOfEstablishedPeers = cfg.targetNumberOfEstablishedPeers;
              TargetNumberOfActivePeers = cfg.targetNumberOfActivePeers;
              TestEnableDevelopmentNetworkProtocols = true;
              MaxConcurrencyBulkSync = 2;
            })) cfg.extraNodeConfig;
        baseInstanceConfig =
          i:
          if !cfg.useLegacyTracing
          then baseConfig //
               { ## XXX: remove once legacy tracing is dropped
                 minSeverity = "Critical";
                 setupScribes = [];
                 setupBackends = [];
                 defaultScribes = [];
                 defaultBackends = [];
                 options = {};
               }
          else baseConfig //
               (optionalAttrs (baseConfig ? hasEKG) {
                  hasEKG = baseConfig.hasEKG + i;
               }) //
               (optionalAttrs (baseConfig ? hasPrometheus) {
                 hasPrometheus = map (n: if isInt n then n + i else n) baseConfig.hasPrometheus;
               });
    in i: let
    instanceConfig = recursiveUpdate (baseInstanceConfig i) (cfg.extraNodeInstanceConfig i);
    nodeConfigFile = if (cfg.nodeConfigFile != null) then cfg.nodeConfigFile
      else toFile "config-${toString cfg.nodeId}-${toString i}.json" (toJSON instanceConfig);
    newTopology = {
      LocalRoots = {
        groups = map (g: {
          localRoots = {
            inherit (g) accessPoints;
            advertise = g.advertise or false;
          };
          valency = g.valency or (length g.accessPoints);
        }) (cfg.producers ++ (cfg.instanceProducers i));
      };
      PublicRoots = map (g: {
        publicRoots = {
          inherit (g) accessPoints;
          advertise = g.advertise or false;
        };
      }) (cfg.publicProducers ++ (cfg.instancePublicProducers i));
    } // optionalAttrs (cfg.usePeersFromLedgerAfterSlot != null) {
      useLedgerAfterSlot = cfg.usePeersFromLedgerAfterSlot;
    };
    oldTopology = {
      Producers = concatMap (g: map (a: {
          addr = a.address;
          inherit (a) port;
          valency = a.valency or 1;
        }) g.accessPoints) (
        cfg.producers ++ (cfg.instanceProducers i) ++ cfg.publicProducers ++ (cfg.instancePublicProducers i)
      );
    };
    topology = if cfg.topology != null then cfg.topology else toFile "topology.yaml" (toJSON (
      if (cfg.useNewTopology) then newTopology
      else oldTopology
    ));
    consensusParams = {
      RealPBFT = [
        "${lib.optionalString (cfg.signingKey != null)
          "--signing-key ${cfg.signingKey}"}"
        "${lib.optionalString (cfg.delegationCertificate != null)
          "--delegation-certificate ${cfg.delegationCertificate}"}"
      ];
      TPraos = [
        "${lib.optionalString (cfg.vrfKey != null)
          "--shelley-vrf-key ${cfg.vrfKey}"}"
        "${lib.optionalString (cfg.kesKey != null)
          "--shelley-kes-key ${cfg.kesKey}"}"
        "${lib.optionalString (cfg.operationalCertificate != null)
          "--shelley-operational-certificate ${cfg.operationalCertificate}"}"
      ];
      Cardano = [
        "${lib.optionalString (cfg.signingKey != null)
          "--signing-key ${cfg.signingKey}"}"
        "${lib.optionalString (cfg.delegationCertificate != null)
          "--delegation-certificate ${cfg.delegationCertificate}"}"
        "${lib.optionalString (cfg.vrfKey != null)
          "--shelley-vrf-key ${cfg.vrfKey}"}"
        "${lib.optionalString (cfg.kesKey != null)
          "--shelley-kes-key ${cfg.kesKey}"}"
        "${lib.optionalString (cfg.operationalCertificate != null)
          "--shelley-operational-certificate ${cfg.operationalCertificate}"}"
      ];
    };
    instanceDbPath = "${cfg.databasePath i}${optionalString (i > 0) "-${toString i}"}";
    cmd = builtins.filter (x: x != "") [
      "${cfg.executable} run"
      "--config ${nodeConfigFile}"
      "--database-path ${instanceDbPath}"
      "--topology ${topology}"
    ] ++ lib.optionals (!cfg.systemdSocketActivation) [
      "--host-addr ${cfg.hostAddr}"
      "--port ${toString (cfg.port + i)}"
      "--socket-path ${cfg.socketPath i}"
    ] ++ lib.optionals (cfg.tracerSocketPathAccept != null && cfg.tracerSocketPathAccept i != null) [
        "--tracer-socket-path-accept ${cfg.tracerSocketPathAccept i}"
    ] ++ lib.optionals (cfg.tracerSocketPathConnect != null && cfg.tracerSocketPathConnect i != null) [
        "--tracer-socket-path-connect ${cfg.tracerSocketPathConnect i}"
    ] ++ lib.optionals (cfg.ipv6HostAddr i != null) [
        "--host-ipv6-addr ${cfg.ipv6HostAddr i}"
    ] ++ consensusParams.${cfg.nodeConfig.Protocol} ++ cfg.extraArgs ++ cfg.rtsArgs;
    in ''
        echo "Starting: ${concatStringsSep "\"\n   echo \"" cmd}"
        echo "..or, once again, in a single line:"
        echo "${toString cmd}"
        ${lib.optionalString (i > 0) ''
        # If exist copy state from existing instance instead of syncing from scratch:
        if [ ! -d ${instanceDbPath} ] && [ -d ${cfg.databasePath i} ]; then
          echo "Copying existing immutable db from ${cfg.databasePath i}"
          ${pkgs.rsync}/bin/rsync --archive --ignore-errors --exclude 'clean' ${cfg.databasePath i}/ ${instanceDbPath}/ || true
        fi
        ''}
        ${toString cmd}'';
in {
  options = {
    services.cardano-node = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enable cardano-node, a node implementing ouroboros protocols
          (the blockchain protocols running cardano).
        '';
      };
      instances = mkOption {
        type = types.int;
        default = 1;
        description = ''
          Number of instance of the service to run.
        '';
      };
      script = mkOption {
        type = types.str;
        default = mkScript cfg 0;
      };

      profiling = mkOption {
        type = types.enum ["none" "time" "space" "space-cost" "space-module" "space-closure" "space-type" "space-retainer" "space-bio" "space-heap"];
        default = "none";
      };

      eventlog = mkOption {
        type = types.bool;
        default = false;
      };

      asserts = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to use an executable with asserts enabled.
        '';
      };

      cardanoNodePackages = mkOption {
        type = types.attrs;
        default = pkgs.cardanoNodePackages or (import ../. {}).cardanoNodePackages;
        defaultText = "cardano-node packages";
        description = ''
          The cardano-node packages and library that should be used.
          Main usage is sharing optimization:
          reduce eval time when service is instantiated multiple times.
        '';
      };

      package = mkOption {
        type = types.package;
        default = if (cfg.profiling != "none")
          then cfg.cardanoNodePackages.cardano-node.profiled
          else if cfg.eventlog then cfg.cardanoNodePackages.cardano-node.eventlogged
          else if cfg.asserts then cfg.cardanoNodePackages.cardano-node.asserted
          else cfg.cardanoNodePackages.cardano-node;
        defaultText = "cardano-node";
        description = ''
          The cardano-node package that should be used
        '';
      };

      executable = mkOption {
        type = types.str;
        default = "exec ${cfg.package}/bin/cardano-node";
        defaultText = "cardano-node";
        description = ''
          The cardano-node executable invocation to use
        '';
      };

      environments = mkOption {
        type = types.attrs;
        default = cfg.cardanoNodePackages.cardanoLib.environments;
        description = ''
          environment node will connect to
        '';
      };

      environment = mkOption {
        type = types.enum (builtins.attrNames cfg.environments);
        default = "testnet";
        description = ''
          environment node will connect to
        '';
      };

      # Byron signing/delegation

      signingKey = mkOption {
        type = types.nullOr (types.either types.str types.path);
        default = null;
        description = ''
          Signing key
        '';
      };

      delegationCertificate = mkOption {
        type = types.nullOr (types.either types.str types.path);
        default = null;
        description = ''
          Delegation certificate
        '';
      };

      # Shelley kes/vrf keys and operation cert

      kesKey = mkOption {
        type = types.nullOr (types.either types.str types.path);
        default = null;
        description = ''
          Signing key
        '';
      };
      vrfKey = mkOption {
        type = types.nullOr (types.either types.str types.path);
        default = null;
        description = ''
          Signing key
        '';
      };

      operationalCertificate = mkOption {
        type = types.nullOr (types.either types.str types.path);
        default = null;
        description = ''
          Operational certificate
        '';
      };

      hostAddr = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = ''
          The host address to bind to
        '';
      };

      ipv6HostAddr = mkOption {
        type = types.nullOr (types.either types.str (types.functionTo (types.nullOr types.str)));
        default = _: null;
        apply = ip: if (builtins.isFunction ip) then ip else _: ip;
        description = ''
          The ipv6 host address to bind to. Set to null to disable.
        '';
      };

      additionalListenStream = mkOption {
        type = types.functionTo (types.listOf types.str);
        default = _: [];
        description = ''
          List of additional sockets to listen to. Only available with `systemdSocketActivation`.
        '';
      };

      stateDir = mkOption {
        type = types.either types.str (types.types.functionTo types.str);
        default = i : "/var/lib/cardano-node-${toString i}";
        apply = x : if (builtins.isFunction x) then x else _: x;
        description = ''
          Directory to store blockchain data, for each instance.
        '';
      };

      runtimeDir = mkOption {
        type = types.nullOr (types.either types.str (types.functionTo types.str));
        default = i : "cardano-node-${toString i}";
        apply = x : if builtins.isFunction x then x else
                       if x == null then _ : "cardano-node" else _ : x;
        description = ''
          Runtime directory relative to /run, for each instance
        '';
      };

      databasePath = mkOption {
        type = types.either types.str (types.functionTo types.str);
        default = i : "${cfg.stateDir i}/${cfg.dbPrefix}";
        apply = x : if builtins.isFunction x then x else _ : x;
        description = ''Node database path, for each instance.'';
      };

      socketPath = mkOption {
        type = types.either types.str (types.functionTo types.str);
        default = i : "${runtimeDir i}/node.socket";
        apply = x : if builtins.isFunction x then x else _ : x;
        description = ''Local communication socket path, for each instance.'';
      };

      tracerSocketPathAccept = mkOption {
        type = types.nullOr (types.either types.str (types.functionTo (types.nullOr types.str)));
        default = null;
        apply = x : if builtins.isFunction x then x else _ : x;
        description = ''
          Listen for incoming cardano-tracer connection on a local socket,
          for each instance.
        '';
      };

      tracerSocketPathConnect = mkOption {
        type = types.nullOr (types.either types.str (types.functionTo (types.nullOr types.str)));
        default = null;
        apply = x : if builtins.isFunction x then x else _ : x;
        description = ''
          Connect to cardano-tracer listening on a local socket,
          for each instance.
        '';
      };

      systemdSocketActivation = mkOption {
        type = types.bool;
        default = false;
        description = ''Use systemd socket activation'';
      };

      extraServiceConfig = mkOption {
        type = types.functionTo types.attrs
          // {
            merge = loc: foldl' (res: def: i: recursiveUpdate (res i) (def.value i)) (i: {});
          };
        default = i: {};
        description = ''
          Extra systemd service config (apply to all instances).
        '';
      };

      extraSocketConfig = mkOption {
        type = types.functionTo types.attrs
          // {
            merge = loc: foldl' (res: def: i: recursiveUpdate (res i) (def.value i)) (i: {});
          };
        default = i: {};
        description = ''
          Extra systemd socket config (apply to all instances).
        '';
      };

      dbPrefix = mkOption {
        type = types.str;
        default = "db-${cfg.environment}";
        description = ''
          Prefix of database directories inside `stateDir`.
          (eg. for "db", there will be db-0, etc.).
        '';
      };

      port = mkOption {
        type = types.either types.int types.str;
        default = 3001;
        description = ''
          The port number
        '';
      };

      shareIpv4port = mkOption {
        type = types.bool;
        default = cfg.systemdSocketActivation;
        description = ''
          Should instances on same machine share ipv4 port.
          Default: true if systemd activated socket. Otherwise always false.
          If false use port increments starting from `port`.
        '';
      };

      shareIpv6port = mkOption {
        type = types.bool;
        default = cfg.systemdSocketActivation;
        description = ''
          Should instances on same machine share ipv6 port.
          Only works with systemd socket.
          Default: true if systemd activated socket. Otherwise always false.
          If false use port increments starting from `port`.
        '';
      };

      nodeId = mkOption {
        type = types.int;
        default = 0;
        description = ''
          The ID for this node
        '';
      };

      publicProducers = mkOption {
        type = types.listOf types.attrs;
        default = [{
          accessPoints = [{
            address = envConfig.relaysNew;
            port = envConfig.edgePort;
          }];
          advertise = false;
        }];
        description = ''Routes to public peers. Only used if slot < usePeersFromLedgerAfterSlot'';
      };

      instancePublicProducers = mkOption {
        # type = types.functionTo (types.listOf types.attrs);
        default = _: [];
        description = ''Routes to public peers. Only used if slot < usePeersFromLedgerAfterSlot and specific to a given instance (when multiple instances are used).'';
      };

      producers = mkOption {
        type = types.listOf types.attrs;
        default = [];
        example = [{
          accessPoints = [{
            address = "127.0.0.1";
            port = 3001;
          }];
          advertise = false;
          valency = 1;
        }];
        description = ''Static routes to local peers.'';
      };

      instanceProducers = mkOption {
        type = types.functionTo (types.listOf types.attrs);
        default = _: [];
        description = ''
          Static routes to local peers, specific to a given instance (when multiple instances are used).
        '';
      };

      useNewTopology = mkOption {
        type = types.bool;
        default = cfg.nodeConfig.EnableP2P or false;
        description = ''
          Use new, p2p/ledger peers compatible topology.
        '';
      };

      useLegacyTracing = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Use the legacy tracing, based on iohk-monitoring-framework.
        '';
      };

      usePeersFromLedgerAfterSlot = mkOption {
        type = types.nullOr types.int;
        default = if cfg.kesKey != null then null
          else envConfig.usePeersFromLedgerAfterSlot or null;
        description = ''
          If set, bootstraps from public roots until it reaches given slot,
          then it switches to using the ledger as a source of peers. It maintains a connection to its local roots.
          Default to null for block producers.
        '';
      };

      topology = mkOption {
        type = types.nullOr (types.either types.str types.path);
        default = null;
        description = ''
          Cluster topology. If not set `producers` array is used to generated topology file.
        '';
      };

      nodeConfig = mkOption {
        type = types.attrs // {
          merge = loc: foldl' (res: def: recursiveUpdate res def.value) {};
        };
        default = envConfig.nodeConfig;
        description = ''Internal representation of the config.'';
      };

      targetNumberOfRootPeers = mkOption {
        type = types.int;
        default = cfg.nodeConfig.TargetNumberOfRootPeers or 100;
        description = "Limits the maximum number of root peers the node will know about";
      };

      targetNumberOfKnownPeers = mkOption {
        type = types.int;
        default = cfg.nodeConfig.TargetNumberOfKnownPeers or cfg.targetNumberOfRootPeers;
        description = ''
          Target number for known peers (root peers + peers known through gossip).
          Default to targetNumberOfRootPeers.
        '';
      };

      targetNumberOfEstablishedPeers = mkOption {
        type = types.int;
        default = cfg.nodeConfig.TargetNumberOfEstablishedPeers
          or (cfg.targetNumberOfKnownPeers / 2);
        description = ''Number of peers the node will be connected to, but not necessarily following their chain.
          Default to half of targetNumberOfKnownPeers.
        '';
      };

      targetNumberOfActivePeers = mkOption {
        type = types.int;
        default = cfg.nodeConfig.TargetNumberOfActivePeers or (2 * cfg.targetNumberOfEstablishedPeers / 5);
        description = ''Number of peers your node is actively downloading headers and blocks from.
          Default to 2/5 of targetNumberOfEstablishedPeers.
        '';
      };

      extraNodeConfig = mkOption {
        type = types.attrs // {
          merge = loc: foldl' (res: def: recursiveUpdate res def.value) {};
        };
        default = {};
        description = ''Additional node config.'';
      };

      extraNodeInstanceConfig = mkOption {
        type = types.functionTo types.attrs
          // {
            merge = loc: foldl' (res: def: i: recursiveUpdate (res i) (def.value i)) (i: {});
          };
        default = i: {};
        description = ''Additional node config for a particular instance.'';
      };

      nodeConfigFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''Actual configuration file (shell expression).'';
      };

      forceHardForks = mkOption {
        type = types.attrsOf types.int;
        default = {};
        description = ''
          A developer-oriented dictionary option to force hard forks for given eras at given epochs.  Maps capitalised era names (Shelley, Allegra, Mary, etc.) to hard fork epoch number.
          '';
      };

      extraArgs = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''Extra CLI args for 'cardano-node'.'';
      };

      rtsArgs = mkOption {
        type = types.listOf types.str;
        default = [ "-N2" "-I0" "-A16m" "-qg" "-qb" "--disable-delayed-os-memory-return" ];
        apply = args: if (args != [] || cfg.profilingArgs != []) then
          ["+RTS"] ++ cfg.profilingArgs ++ args ++ ["-RTS"]
          else [];
        description = ''Extra CLI args for 'cardano-node', to be surrounded by "+RTS"/"-RTS"'';
      };

      profilingArgs = mkOption {
        type = types.listOf types.str;
        default = let commonProfilingArgs = ["--machine-readable" "-tcardano-node.stats" "-pocardano-node"]
          ++ lib.optional (cfg.eventlog) "-l";
          in if cfg.profiling == "time" then ["-P"] ++ commonProfilingArgs
            else if cfg.profiling == "space" then ["-h"] ++ commonProfilingArgs
            else if cfg.profiling == "space-cost" then ["-hc"] ++ commonProfilingArgs
            else if cfg.profiling == "space-module" then ["-hm"] ++ commonProfilingArgs
            else if cfg.profiling == "space-closure" then ["-hd"] ++ commonProfilingArgs
            else if cfg.profiling == "space-type" then ["-hy"] ++ commonProfilingArgs
            else if cfg.profiling == "space-retainer" then ["-hr"] ++ commonProfilingArgs
            else if cfg.profiling == "space-bio" then ["-hb"] ++ commonProfilingArgs
            else if cfg.profiling == "space-heap" then ["-hT"] ++ commonProfilingArgs
            else [];
        description = ''RTS profiling options'';
      };
    };
  };

  config = mkIf cfg.enable ( let
    stateDirBase = "/var/lib/";
    runDirBase = "/run/";
    genInstanceConf = f: listToAttrs (if cfg.instances > 1
      then genList (i: let n = "cardano-node-${toString i}"; in nameValuePair n (f n i)) cfg.instances
      else [ (nameValuePair "cardano-node" (f "cardano-node" 0)) ]); in lib.mkMerge [
    {
      users.groups.cardano-node.gid = 10016;
      users.users.cardano-node = {
        description = "cardano-node node daemon user";
        uid = 10016;
        group = "cardano-node";
        isSystemUser = true;
      };

      ## TODO:  use http://hackage.haskell.org/package/systemd for:
      ##   1. only declaring success after we perform meaningful init (local state recovery)
      ##   2. heartbeat & watchdog functionality
      systemd.services = genInstanceConf (n: i: recursiveUpdate {
        description   = "cardano-node node ${toString i} service";
        after         = [ "network-online.target" ]
          ++ (optional cfg.systemdSocketActivation "${n}.socket")
          ++ (optional (cfg.instances > 1) "cardano-node.service");
        requires = optional cfg.systemdSocketActivation "${n}.socket"
          ++ (optional (cfg.instances > 1) "cardano-node.service");
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        partOf = mkIf (cfg.instances > 1) ["cardano-node.service"];
        script = mkScript cfg i;
        serviceConfig = {
          User = "cardano-node";
          Group = "cardano-node";
          Restart = "always";
          RuntimeDirectory = lib.mkIf (!cfg.systemdSocketActivation)
            (lib.removePrefix runDirBase (runtimeDir i));
          WorkingDirectory = cfg.stateDir i;
          # This assumes /var/lib/ is a prefix of cfg.stateDir.
          # This is checked as an assertion below.
          StateDirectory =  lib.removePrefix stateDirBase (cfg.stateDir i);
          NonBlocking = lib.mkIf cfg.systemdSocketActivation true;
          # time to sleep before restarting a service
          RestartSec = 1;
        };
      } (cfg.extraServiceConfig i));

      systemd.sockets = genInstanceConf (n: i: lib.mkIf cfg.systemdSocketActivation (recursiveUpdate {
        description = "Socket of the ${n} service.";
        wantedBy = [ "sockets.target" ];
        partOf = [ "${n}.service" ];
        socketConfig = {
          ListenStream = [ "${cfg.hostAddr}:${toString (if cfg.shareIpv4port then cfg.port else cfg.port + i)}" ]
            ++ optional (cfg.ipv6HostAddr i != null) "[${cfg.ipv6HostAddr i}]:${toString (if cfg.shareIpv6port then cfg.port else cfg.port + i)}"
            ++ (cfg.additionalListenStream i)
            ++ [(cfg.socketPath i)];
          RuntimeDirectory = lib.removePrefix runDirBase
            (cfg.runtimeDir i);
          ReusePort = "yes";
          SocketMode = "0660";
          SocketUser = "cardano-node";
          SocketGroup = "cardano-node";
          FreeBind = "yes";
        };
      } (cfg.extraSocketConfig i)));
    }
    {
      # oneshot service start allows to easily control all instances at once.
      systemd.services.cardano-node = lib.mkIf (cfg.instances > 1) {
        description = "Control all ${toString cfg.instances} at once.";
        enable  = true;
        wants = genList (i: "cardano-node-${toString i}.service") cfg.instances;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = "yes";
          User = "cardano-node";
          Group = "cardano-node";
          ExecStart = "${pkgs.coreutils}/bin/echo Starting ${toString cfg.instances} cardano-node instances";
          WorkingDirectory = oneShotStateDir;
          StateDirectory =  lib.removePrefix stateDirBase oneShotStateDir;
        };
      };
    }
    {
      assertions = [
        {
          assertion = builtins.all (i : lib.hasPrefix stateDirBase (cfg.stateDir i))
                                   (builtins.genList lib.trivial.id cfg.instances);
          message = "The option services.cardano-node.stateDir should have ${stateDirBase}
                     as a prefix, for each instance!";
        }
        {
          assertion = (cfg.kesKey == null) == (cfg.vrfKey == null) && (cfg.kesKey == null) == (cfg.operationalCertificate == null);
          message = "Shelley Era: all of three [operationalCertificate kesKey vrfKey] options must be defined (or none of them).";
        }
      ];
    }
  ]);
}
