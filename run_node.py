#!/usr/bin/env python3

import os
import sys
import json
import argparse
from src.network.node import Node
from src.core.blockchain import Blockchain

def main():
    parser = argparse.ArgumentParser(description='Jalankan node Ghalbir Blockchain')
    parser.add_argument('--host', type=str, help='Host untuk menjalankan node')
    parser.add_argument('--port', type=int, help='Port untuk menjalankan node')
    parser.add_argument('--difficulty', type=int, help='Tingkat kesulitan untuk proof of work')
    parser.add_argument('--mining-reward', type=int, help='Reward untuk mining')
    parser.add_argument('--verbose', action='store_true', help='Mode verbose')
    args = parser.parse_args()
    
    # Baca konfigurasi
    config = {}
    if os.path.exists('config.json'):
        with open('config.json', 'r') as f:
            config = json.load(f)
    
    # Gunakan argumen command line jika ada, jika tidak gunakan konfigurasi
    host = args.host or config.get('node', {}).get('host', '0.0.0.0')
    port = args.port or config.get('node', {}).get('port', 5000)
    difficulty = args.difficulty or config.get('node', {}).get('difficulty', 4)
    mining_reward = args.mining_reward or config.get('node', {}).get('mining_reward', 50)
    
    # Inisialisasi blockchain
    blockchain = Blockchain(difficulty=difficulty, mining_reward=mining_reward)
    
    # Inisialisasi node
    node = Node(host=host, port=port)
    node.blockchain = blockchain
    
    # Tambahkan peer dari konfigurasi
    for peer in config.get('node', {}).get('peers', []):
        node.add_peer(peer)
    
    print(f"Memulai node Ghalbir Blockchain di {host}:{port}")
    print(f"Tingkat kesulitan: {difficulty}")
    print(f"Mining reward: {mining_reward}")
    
    # Mulai node
    node.start()
    
    try:
        # Jaga agar program tetap berjalan
        while True:
            cmd = input("Masukkan 'exit' untuk keluar: ")
            if cmd.lower() == 'exit':
                break
    except KeyboardInterrupt:
        print("\nMenghentikan node...")
    finally:
        node.stop()

if __name__ == '__main__':
    main()
