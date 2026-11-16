"""Physical tile assignments used by both fp_plan and the compiled RTL."""
COLS, ROWS = 5, 4
TILES = tuple([f"Rocket{i}" for i in range(12)] + [f"BOOM{i}" for i in range(4)] + [f"Gemmini{i}" for i in range(3)] + ["Host"])
assert len(TILES) == COLS * ROWS
GEMMINIS = tuple(i for i, name in enumerate(TILES) if name.startswith("Gemmini"))
GEMMINI, HOST = GEMMINIS[0], TILES.index("Host")
# Pins face out at the northeast corner of the block. RX/TX are relative to the SoC.
HOST_PINS = {"host_req": (36000, 31500), "host_rsp": (36000, 31600),
             "mem_req": (36000, 31700), "mem_rsp": (36000, 31800)}


def links():
    """Undirected mesh links and port number at each end: west/east/south/north."""
    for tile in range(len(TILES)):
        if tile % COLS:
            yield tile - 1, 1, tile, 0
        if tile >= COLS:
            yield tile - COLS, 3, tile, 2
