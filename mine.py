#!/usr/bin/env python3

import os
import sys
import json
import time
import argparse
from src.core.blockchain import Blockchain
import firebase_admin
from firebase_admin import auth, credentials

cred = credentials.Certificate("serviceAccountKey.json")  # Download dari Firebase Console
firebase_admin.initialize_app(cred)

def verify_firebase_token(id_token: str):
    try:
        decoded_token = auth.verify_id_token(id_token)
        uid = decoded_token['uid']
        return uid
    except Exception as e:
        raise HTTPException(status_code=401, detail="Token tidak valid")

def main():
    parser = argparse.ArgumentParser(description='Mining Ghalbir Blockchain')
    parser.add_argument('--address', type=str, required=True, help='Alamat wallet untuk menerima reward')
    parser.add_argument('--blockchain-file', type=str, help='File blockchain')
    parser.add_argument('--blocks', type=int, help='Jumlah blok yang akan di-mining')
    parser.add_argument('--auto', action='store_true', help='Mode mining otomatis')
    args = parser.parse_args()
    
    blockchain_file = args.blockchain_file or 'blockchain.json'
    
    # Inisialisasi blockchain
    if os.path.exists(blockchain_file):
        blockchain = Blockchain.load_from_file(blockchain_file)
    else:
        blockchain = Blockchain()
    
    # Mining
    if args.blocks:
        # Mining sejumlah blok tertentu
        for i in range(args.blocks):
            print(f"Mining blok {i+1}/{args.blocks}...")
            block = blockchain.mine_pending_transactions(args.address)
            print(f"Blok berhasil di-mining! Hash: {block.hash}")
            
            # Simpan blockchain
            blockchain.save_to_file(blockchain_file)
    elif args.auto:
        # Mining otomatis
        try:
            print("Memulai mining otomatis. Tekan Ctrl+C untuk berhenti.")
            while True:
                # Tambahkan transaksi dummy jika tidak ada transaksi tertunda
                if len(blockchain.pending_transactions) == 0:
                    from src.core.transaction import Transaction
                    tx = Transaction("0x0", args.address, 0)
                    blockchain.add_transaction(tx)
                
                print("Mining blok...")
                block = blockchain.mine_pending_transactions(args.address)
                print(f"Blok berhasil di-mining! Hash: {block.hash}")
                
                # Simpan blockchain
                blockchain.save_to_file(blockchain_file)
                
                # Tunggu sebentar
                time.sleep(10)
        except KeyboardInterrupt:
            print("\nMining dihentikan.")
    else:
        # Mining satu blok
        print("Mining blok...")
        block = blockchain.mine_pending_transactions(args.address)
        print(f"Blok berhasil di-mining! Hash: {block.hash}")
        
        # Simpan blockchain
        blockchain.save_to_file(blockchain_file)
    
    # Tampilkan saldo
    balance = blockchain.get_balance(args.address)
    print(f"Saldo: {balance} GBR")

if __name__ == '__main__':
    main()
