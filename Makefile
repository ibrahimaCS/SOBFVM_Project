# =============================================================================
# Makefile for the SOBF virtual machine (PRIM11 2025-2026)
# =============================================================================
# Available targets:
#   make            -> build the sobfvm executable
#   make clean      -> remove object files and the executable
#   make rebuild    -> clean then build from scratch
# =============================================================================

# --- Compiler and flags ---
CC      = gcc
CFLAGS  = -Wall -Wextra -g -Iinclude
LDFLAGS =

# --- Directories ---
SRC_DIR = src
INC_DIR = include
OBJ_DIR = obj

# --- Automatic source discovery ---
# wildcard collects every .c in src/, and patsubst maps each one to its
# corresponding object file path under obj/.
SRCS = $(wildcard $(SRC_DIR)/*.c)
OBJS = $(patsubst $(SRC_DIR)/%.c,$(OBJ_DIR)/%.o,$(SRCS))

# --- Final executable name ---
EXEC = sobfvm

# --- Default target ---
all: $(EXEC)

# --- Linking step ---
$(EXEC): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

# --- Compilation step ---
# Each src/x.c becomes obj/x.o.
$(OBJ_DIR)/%.o: $(SRC_DIR)/%.c | $(OBJ_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

# --- Create the obj/ directory if missing ---
$(OBJ_DIR):
	mkdir -p $(OBJ_DIR)

# --- Cleaning ---
clean:
	rm -rf $(OBJ_DIR) $(EXEC)

# --- Full rebuild ---
rebuild: clean all

.PHONY: all clean rebuild
