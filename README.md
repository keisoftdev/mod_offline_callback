mod_http_offline
================

Ejabberd module to send a post if users was offline.


This module is based on [Adam Duke mod_interact](https://github.com/adamvduke/mod_interact), [Jason Rowe's post](http://jasonrowe.com/2011/12/30/ejabberd-offline-messages/) and a lot of pieces of code and tips from the web to adapts to work with Ejabber 14.12.

## Prerequisites

* Erlang/OTP 19 or higher
* ejabberd 18.01

## Installation

```bash
# Substitute ~ for the home directory of the user that runs ejabberd:
cd ~/.ejabberd-modules/sources/
git clone https://github.com/keisoftdev/mod_offline_callback.git
# ejabberdctl should now list mod_offline_callback as available:
ejabberdctl modules_available
# Compile and install mod_offline_callback:
ejabberdctl module_install mod_offline_callback
```

### Upgrading

```bash
ejabberdctl module_upgrade mod_offline_callback # same as uninstall + install
```

`module_upgrade` does not restart modules and thus leaves mod_offline_callback stopped.
Kick it manually inside `ejabberdctl debug`:

``` erlang
l(mod_pushoff_apns).
[catch gen_mod:start_module(Host, mod_offline_callback) || Host <- ejabberd_config:get_myhosts()].
```


### Operation Notes

``` erlang
% Divert logs:
lager:trace_file("/tmp/mod_offline_callback.log", [{module, mod_offline_callback}], debug).
% Tracing (install recon first from https://github.com/ferd/recon):
code:add_patha("/Users/vladki/src/recon/ebin"),
recon_trace:calls({mod_pushoff, on_offline_message, '_'}, 100),
recon_trace:calls({jiffy, encode, fun(_) -> return_trace() end}, 100).
```


## Configuration

```yaml
modules:
  # mod_offline is a hard dependency
  mod_offline: {}
  mod_offline_callback:
    backends:
      -
        type: url
        gateway: "https://your.api.offline.callback.url"
```
