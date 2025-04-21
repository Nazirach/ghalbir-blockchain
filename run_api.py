#!/usr/bin/env python3

import os
import sys
import json
import argparse
from src.core.blockchain import Blockchain
from src.vm.virtual_machine import VirtualMachine
from src.api.metamask_api import MetaMaskAPI

def main():
    parser = argparse.ArgumentParser(description='Jalankan API Ghalbir Blockchain')
    parser.add_argument('--host', type=str, help='Host untuk menjalankan API')
    parser.add_argument('--port', type=int, help='Port untuk menjalankan API')
    parser.add_argument('--blockchain-file', type=str, help='File blockchain')
    parser.add_argument('--verbose', action='store_true', help='Mode verbose')
    args = parser.parse_args()
    
    # Baca konfigurasi
    config = {}
    if os.path.exists('config.json'):
        with open('config.json', 'r') as f:
            config = json.load(f)
    
    # Gunakan argumen command line jika ada, jika tidak gunakan konfigurasi
    host = args.host or config.get('api', {}).get('host', '0.0.0.0')
    port = args.port or config.get('api', {}).get('port', 8545)
    blockchain_file = args.blockchain_file or 'blockchain.json'
    
    # Inisialisasi blockchain
    if os.path.exists(blockchain_file):
        blockchain = Blockchain.load_from_file(blockchain_file)
    else:
        blockchain = Blockchain()
    
    # Inisialisasi VM
    vm = VirtualMachine(blockchain)
    
    # Inisialisasi API
    api = MetaMaskAPI(blockchain, vm)
    
    print(f"Memulai API Ghalbir Blockchain di {host}:{port}")
    
    # Mulai API
    api.start(host=host, port=port)

if __name__ == '__main__':
    main()
