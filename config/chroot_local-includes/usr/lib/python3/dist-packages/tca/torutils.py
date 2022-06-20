#!/usr/bin/python3

from pathlib import Path
import re
import subprocess
import ipaddress
import time
import logging
import os
import json
import socket
from stem.control import Controller
import stem.socket
from typing import List, Optional, Dict, Any, Tuple, cast, Callable
import tca.config

log = logging.getLogger("tor-launcher")


class StemFDSocket(stem.socket.ControlSocket):
    def __init__(self, fd: int):
        super().__init__()
        self.fd = fd
        self._is_alive = True

    @property
    def path(self) -> str:
        """
        I don't think that's ever called, but let's implement it

        returns sth like socket:[12345678], which is not great
        """
        fname = "/proc/%d/fd/%d" % (os.getpid(), self.fd)
        return Path(fname).resolve().name

    def _make_socket(self):
        """
        We don't need to create a new socket: let's reuse the FD!
        """
        return socket.socket(fileno=self.fd)


def recover_fd_from_parent() -> tuple:
    fds = [int(fd) for fd in os.getenv("INHERIT_FD", "").split(",")]
    # fds[0] must be a rw fd for settings file
    # fds[1] must be a rw fd for state file
    # fds[2] must be a socket to tca-portal

    configfile = os.fdopen(fds[0], "r+")
    statefile = os.fdopen(fds[1], "r+")
    portal = socket.socket(fileno=fds[2])

    return (configfile, statefile, portal)


# PROXY_TYPES is a sequence of Tor options related to proxing.
#     Those exact values are also used by TorConnectionProxy
PROXY_TYPES = ("Socks4Proxy", "Socks5Proxy", "HTTPSProxy")
PROXY_AUTH_OPTIONS = {
    "HTTPSProxy": ["HTTPSProxyAuthenticator"],
    "Socks5Proxy": ["Socks5ProxyUsername", "Socks5ProxyPassword"],
    "Socks4Proxy": [],
}


class TorConnectionProxy:
    """configuration item for proxy configuration"""

    def __init__(
        self,
        address: str,
        port: int,
        proxy_type: str,
        auth: Optional[Tuple[str, str]] = None,
        enabled: bool = True,
    ):
        self.enabled = enabled
        self.proxy_type = proxy_type
        self.address = address
        self.port = port
        self.auth = auth
        if not enabled:
            return
        if proxy_type not in PROXY_TYPES:
            raise ValueError("Invalid proxy type: `%s`" % proxy_type)
        if proxy_type == "Socks4Proxy" and auth is not None:
            raise ValueError("Socks4Proxy cannot have authentication")

    @classmethod
    def noproxy(cls) -> "TorConnectionProxy":
        r = cls(address="", port=0, proxy_type="", enabled=False)
        return r

    @classmethod
    def from_obj(cls, obj: dict) -> "TorConnectionProxy":
        kwargs = dict(
            proxy_type=obj["proxy_type"], address=obj["address"], port=int(obj["port"])
        )
        auth: Tuple[Optional[str], Optional[str]] = (
            obj.get("username"),
            obj.get("password"),
        )
        if all(x is None for x in auth):
            kwargs["auth"] = None
        elif any(x is None for x in auth):
            raise ValueError(
                "Proxy configuration object username and password must all be set, or none at all"
            )
        else:
            kwargs["auth"] = auth
        proxy = cls(**kwargs)
        return proxy

    def to_dict(self):
        if not self.enabled:
            return None
        r = {"proxy_type": self.proxy_type, "address": self.address, "port": self.port}
        if self.auth is not None:
            r["username"], r["password"] = self.auth
        return r

    @classmethod
    def from_tor_value(
        cls, proxy_type: str, val: str, auth_values: Optional[List[str]] = None
    ) -> "TorConnectionProxy":
        address, port = val.split(":")
        auth: Optional[Tuple[str, str]] = None
        if auth_values and any(auth_values):
            if len(auth_values) == 1:
                auth = cast(Tuple[str, str], tuple(auth_values[0].split(":", 1)))
            elif len(auth_values) == 2:
                auth = cast(Tuple[str, str], tuple(auth_values))
            else:
                raise ValueError(
                    "auth_values must either be ['user:password'] "
                    " or ['user', 'password'], not %s" % repr(auth_values)
                )

        obj = cls(address, int(port), proxy_type, auth=auth)
        return obj

    def to_tor_value_options(self) -> Dict[str, Optional[str]]:
        r: Dict[str, Optional[str]] = {}
        if self.enabled:
            r[self.proxy_type] = "%s:%d" % (self.address, self.port)
        for proxy_type in PROXY_TYPES:
            if self.enabled and proxy_type == self.proxy_type:
                continue
            r[proxy_type] = None
        for ptype in PROXY_TYPES:
            for option in PROXY_AUTH_OPTIONS.get(ptype, []):
                r[option] = None
        if self.enabled and self.auth is not None:
            if self.proxy_type == "HTTPSProxy":
                r["HTTPSProxyAuthenticator"] = "%s:%s" % self.auth
            else:
                r["Socks5ProxyUsername"], r["Socks5ProxyPassword"] = self.auth
        return r


class InvalidBridgeException(ValueError):
    pass


class MalformedBridgeException(InvalidBridgeException):
    pass


class InvalidBridgeTypeException(InvalidBridgeException):
    pass


VALID_BRIDGE_TYPES = {"bridge", "obfs4"}


class TorConnectionConfig:
    def __init__(
        self,
        bridges: list = [],
        proxy: TorConnectionProxy = TorConnectionProxy.noproxy(),
    ):
        self.bridges: List[str] = bridges
        self.proxy: TorConnectionProxy = proxy

    def bridge_line_is_simple(self, line):
        if line.split()[0].lower() == 'bridge':
            return True
        try:
            ipaddress.ip_address(line.split(":")[0])
        except ValueError:
            return False
        return True

    def disable_bridges(self):
        self.bridges.clear()

    @classmethod
    def parse_bridge_line(cls, line: str) -> Optional[str]:
        """
        Validate bridges syntax.

        Empty lines are ignored
        >>> TorConnectionConfig.parse_bridge_line("  ")

        Just like comments
        >>> TorConnectionConfig.parse_bridge_line(" # 1.2.3.4:443")

        normal bridges are ok
        >>> TorConnectionConfig.parse_bridge_line("1.2.3.4:25")
        '1.2.3.4:25'

        specifying "normal" is fine, too
        >>> TorConnectionConfig.parse_bridge_line("bridge 1.2.3.4:25")
        '1.2.3.4:25'


        spaces are normalized
        >>> TorConnectionConfig.parse_bridge_line("  obfs4   1.2.3.4:25 foo")
        'obfs4 1.2.3.4:25 foo'

        An error is raised if the IP is not valid
        >>> TorConnectionConfig.parse_bridge_line("1.2.3:25")
        Traceback (most recent call last):
            ...
        ValueError: '1.2.3' does not appear to be an IPv4 or IPv6 address

        An error is raised if the IP-port malformed is not valid
        >>> TorConnectionConfig.parse_bridge_line("1.2.3.4")
        Traceback (most recent call last):
            ...
        torutils.MalformedBridgeException: Bridge address is malformed: '1.2.3.4'
        >>> TorConnectionConfig.parse_bridge_line("1.2.3.4:1000:1000")
        Traceback (most recent call last):
            ...
        ValueError: '1.2.3.4:1000' does not appear to be an IPv4 or IPv6 address

        IPv6 is fine
        >>> TorConnectionConfig.parse_bridge_line("[::1]:1000")
        '[::1]:1000'
        """
        line = line.strip()
        if not line:
            return None
        if line.startswith("#"):
            return None
        parts = line.split()
        transport_name_re = re.compile(r"^[a-zA-Z0-9_]+$")
        if not transport_name_re.match(parts[0]):
            parts.insert(0, "bridge")
        bridge_ip_port = parts[1]
        bridge_parts = bridge_ip_port.rsplit(":", 1)
        if len(bridge_parts) != 2:
            raise MalformedBridgeException(
                "Bridge address is malformed: '%s'" % bridge_ip_port
            )
        bridge_ip, bridge_port = bridge_parts
        get_ip = ipaddress.ip_address
        if bridge_ip.startswith("[") and bridge_ip.endswith("]"):
            bridge_ip = bridge_ip[1:-1]
            get_ip = ipaddress.IPv6Address

        try:
            get_ip(bridge_ip)
        except ValueError:
            raise
        try:
            int(bridge_port)
        except ValueError:
            raise
        if int(bridge_port) > 65535:
            raise ValueError("invalid port number")

        if parts[0] not in VALID_BRIDGE_TYPES:
            raise InvalidBridgeTypeException(
                "Bridge type '%s' not supported" % parts[0]
            )
        if parts[0] == "bridge":  # normal can be omitted
            del parts[0]
        return " ".join(parts)

    @classmethod
    def parse_bridge_lines(cls, lines: List[str]) -> List[str]:
        """
        Parse a list of lines and returns only normalized, meaningful lines.

        Errors will result in an exception being raised (see parse_bridge_line).

        Empty lines are skipped
        >>> TorConnectionConfig.parse_bridge_lines([" bridge 1.2.3.4:80 ", "", "  "])
        ['1.2.3.4:80']
        """
        parsed_bridges = (cls.parse_bridge_line(l) for l in lines)
        return [b for b in parsed_bridges if b]

    @classmethod
    def get_default_bridges(cls, only_type: Optional[str] = None) -> List[str]:
        """Get default bridges from a txt file."""
        bridges = []
        with open(os.path.join(tca.config.data_path, "default_bridges.txt")) as buf:
            for line in buf:
                try:
                    parsed = cls.parse_bridge_line(line)
                except InvalidBridgeException:
                    continue
                if not parsed:
                    continue
                if only_type and parsed.split()[0] != only_type:
                    continue
                bridges.append(parsed)
        return bridges

    def enable_bridges(self, bridges: List[str]):
        if not bridges:
            raise ValueError("Can't set empty bridge list")
        self.bridges.clear()
        bridges = self.__class__.parse_bridge_lines(bridges)
        self.bridges.extend(bridges)

    def enable_default_bridges(self, only_type: Optional[str] = None):
        """
        Set default bridges.

        useful for Tor blocking, not for unnoticed-mode
        """
        bridges = self.__class__.get_default_bridges(only_type)
        self.enable_bridges(bridges)

    @classmethod
    def load_from_tor_stem(
            cls,
            stem_controller: Controller,
    ):
        bridges: List[str] = []
        if stem_controller.get_conf("UseBridges") != "0":
            bridges = stem_controller.get_conf("Bridge", multiple=True)

        for proxy_type in PROXY_TYPES:
            val = stem_controller.get_conf(proxy_type)
            if val is not None:
                auth = [
                    stem_controller.get_conf(opt)
                    for opt in PROXY_AUTH_OPTIONS[proxy_type]
                ]

                proxy = TorConnectionProxy.from_tor_value(
                    proxy_type, val, auth_values=auth
                )
                break
        else:
            proxy = TorConnectionProxy.noproxy()

        config = cls(bridges=bridges, proxy=proxy)

        return config

    @classmethod
    def load_from_dict(cls, obj, load_proxy=False):
        """this method is suitable to retrieve configuration from a JSON object"""
        config = cls()
        config.bridges = obj.get("bridges", [])
        # For now we ignore saved proxy configuration: our configuration
        # is global, while proxy settings only make sense per network.
        # When we implement #18423, we should drop the conditional
        # and the load_proxy argument.
        if load_proxy:
            proxy = obj.get("proxy", None)
            if proxy is not None:
                config.proxy = TorConnectionProxy.from_obj(proxy)
            else:
                config.proxy = TorConnectionProxy.noproxy()
        return config

    def to_dict(self, include_default_bridges: bool = True) -> dict:
        data = {
            "bridges": self.bridges,
            "proxy": self.proxy.to_dict() if self.proxy is not None else None,
        }
        if not include_default_bridges and \
           set(data.get("bridges", [])) == set(self.get_default_bridges()):
            data["bridges"] = []
        return data

    def to_tor_conf(self) -> Dict[str, Any]:
        """
        returns a dict whose output fits to stem.control.Controller.set_options
        """
        r: Dict[str, Any] = {}
        r["UseBridges"] = "1" if self.bridges else "0"
        r["Bridge"] = self.bridges if self.bridges else None
        r.update(self.proxy.to_tor_value_options().items())
        log.debug("TorOpts=%s", r)
        return r

    def can_use_sandbox(self) -> bool:
        """
        Returns True iff. we can enable Tor's Sandbox configuration option.
        """
        return (not self.bridges
                or all([self.bridge_line_is_simple(b) for b in self.bridges]))


class TorLauncherUtils:
    def __init__(self, stem_controller: Controller,
                 config_buf, state_buf,
                 set_tor_sandbox_fn: Callable[[bool], None]):
        """
        Arguments:
        stem_controller -- an already connected and authorized stem Controller
        config_buf -- an already open read-write buffer to the configuration file
        state_buf -- an already open read-write buffer to the state file
        set_tor_sandbox_fn -- a Callable whose argument sets Tor's Sandbox value
        """
        self.stem_controller = stem_controller
        self.config_buf = config_buf
        self.state_buf = state_buf
        self.tor_connection_config = None
        self.set_tor_sandbox_fn = set_tor_sandbox_fn

    def load_conf_from_tor(self):
        if self.tor_connection_config is None:
            log.debug("Loading configuration from tor")
            self.tor_connection_config = TorConnectionConfig.load_from_tor_stem(
                self.stem_controller,
            )

    def load_conf_from_file(self):
        if self.tor_connection_config is None:
            log.debug("Loading configuration from file")
            self.tor_connection_config = TorConnectionConfig.load_from_dict(
                self.read_tca_conf().get("tor", {})
            )

    def save_conf(self):
        if self.tor_connection_config is None:
            return

        # Save configuration to our own configuration file
        data = {
            "tor": self.tor_connection_config.to_dict(
                # We only want to persist custom bridges, not the default ones
                include_default_bridges=False
            )
        }
        encode_to_json_buf(data, self.config_buf)

        # Save configuration to torrc
        self.stem_controller.save_conf()

    def save_tca_state(self, state):
        encode_to_json_buf(state, self.state_buf)

    def read_tca_conf(self):
        return decode_json_from_buf(self.config_buf)

    def read_tca_state(self):
        return decode_json_from_buf(self.state_buf)

    def apply_conf(self, callback: Callable) -> bool:
        """
        Apply the configuration from self.tor_connection_config to the
        running tor daemon, and asynchronously ensure Tor's Sandbox
        configuration option is enabled iff. we can use it.

        Upon completion, the callback is called.

        This method can restart tor.

        Rationale: Tor's Sandbox conf needs special care since this value
        cannot be changed at runtime, only through torrc and a tor restart.
        """
        tor_conf = self.tor_connection_config.to_tor_conf()
        log.debug("applying TorConf: %s", tor_conf)
        self.stem_controller.set_options(tor_conf)

        # We have seen a very odd bug where issuing "DisableNetwork 0"
        # when it already is 0 kills tor. There is a lot of
        # uncertainty remaining around what exactly is going on, and
        # weird stuff like running tor under strace preventing the
        # killing.
        if self.stem_controller.get_conf("DisableNetwork") == "1":
            self.stem_controller.set_conf("DisableNetwork", "0")
        self.stem_controller.save_conf()

        current_sandbox = self.stem_controller.get_conf("Sandbox")
        can_use_sandbox = self.tor_connection_config.can_use_sandbox()
        updating_sandbox_conf = str(int(current_sandbox)) != can_use_sandbox
        if updating_sandbox_conf:
            self.set_tor_sandbox_fn(callback, str(int(can_use_sandbox)))
        return updating_sandbox_conf

    def stop_connecting(self):
        """
        Stop trying to connect to Tor.

        Particularly useful after timeout.
        """
        if self.stem_controller.get_conf("DisableNetwork") == "0":
            self.stem_controller.set_conf("DisableNetwork", "1")
        self.stem_controller.save_conf()

    def tor_bootstrap_phase(self) -> int:
        resp = self.stem_controller.get_info("status/bootstrap-phase")
        if resp is None:
            log.warn("No response from ControlPort")
            return False
        parts = resp.split(" ")
        if parts[0] not in ("NOTICE", "WARN"):
            log.warn("Invalid response: %s", resp)
            return False
        progress = int(parts[2].split("=")[1])
        log.debug("tor bootstrap progress = %d", progress)
        return progress

    def tor_has_bootstrapped(self) -> bool:
        resp = self.stem_controller.get_info('status/circuit-established')
        if resp is None:
            log.warn('No response from Controlport')
            return False
        if resp == '1':
            return True
        if resp == '0':
            return False
        log.warn("Unexpected reply to enough-dir-info: %s", str(resp))
        return False

    def tor_has_circuits(self) -> bool:
        resp = self.stem_controller.get_info("status/circuit-established")
        if resp is None:
            log.warn("No response from ControlPort")
            return False
        if not bool(int(resp)):
            return False

        return True


class TorLauncherNetworkUtils:
    def __init__(self):
        pass

    def is_network_up(self):
        """
        This method checks whether we have an IP on some network interface.

        It does NOT care if we're really connected to the Internet
        """

        # nm-online -xq could be what we need
        raise NotImplementedError()

    def is_internet_up(self):
        """
        This is similar to is_network_up(), but also checks if we're really connected to the Internet
        """
        raise NotImplementedError()

    def open_wifi_screen(self):
        """
        Open NetworkManager wifi configuration screen
        """
        raise NotImplementedError()

    def tor_connect_easy(self):
        """
        tries to connect to Tor without hiding, and with no custom configuration
        """
        raise NotImplementedError()


def backoff_wait(
    total_wait: float = 30.0, initial_sleep: float = 0.5, increment=lambda x: x + 0.5
):
    total_sleep = 0
    sleep_time = initial_sleep
    while total_sleep < total_wait:
        time.sleep(sleep_time)
        total_sleep += sleep_time
        sleep_time = increment(sleep_time)
        yield


def decode_json_from_buf(buf):
    buf.seek(0, os.SEEK_END)
    size = buf.tell()
    if not size:
        log.debug("Empty file")
        return {}
    buf.seek(0)
    try:
        obj = json.load(buf)
    except json.JSONDecodeError:
        log.warning("Invalid file")
        return {}
    finally:
        buf.seek(0)
    return obj


def encode_to_json_buf(data, buf):
    buf.seek(0, os.SEEK_SET)
    buf.truncate()
    buf.write(json.dumps(data, indent=2))
    buf.flush()
