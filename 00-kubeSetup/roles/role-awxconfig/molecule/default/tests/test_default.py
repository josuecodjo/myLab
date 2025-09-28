"""Role testing files using testinfra."""

def test_motd_conf(host):
    motd = host.file("/etc/motd")
    assert motd.exists
