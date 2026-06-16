# Makefile for M7Daemon

CXX = g++
CXXFLAGS = -Wall -O3 -std=c++11

TARGET = m7_daemon
OBJS = m7_daemon.o

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CXX) $(CXXFLAGS) -o $(TARGET) $(OBJS)

m7_daemon.o: m7_daemon.cpp
	$(CXX) $(CXXFLAGS) -c m7_daemon.cpp

clean:
	rm -f $(TARGET) $(OBJS)
