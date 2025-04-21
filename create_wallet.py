#!/usr/bin/env python3

import os
import sys
import json
import argparse
from src.wallet.wallet import Wallet

def main():
    parser = argparse.ArgumentParser(description='Buat wallet Ghalbir Blockchain')
    parser.add_argument('--keystore', type=str, help='File keystore untuk menyimpan wallet')
    parser.add_argument('--password', type=str, help='Password untuk enkripsi keystore')
    args = parser.parse_args()
    
    # Buat wallet baru
    wallet = Wallet()
    
    print("Wallet baru berhasil dibuat!")
    print(f"Alamat: {wallet.address}")
    print(f"Kunci Publik: {wallet.public_key}")
    print(f"Kunci Privat: {wallet.private_key}")
    print("\nPENTING: Simpan kunci privat Anda dengan aman!")
    
    # Simpan ke keystore jika diminta
    if args.keystore:
        if not args.password:
            password = input("Masukkan password untuk enkripsi keystore: ")
        else:
            password = args.password
        
        keystore_file = wallet.export_keystore(password, args.keystore)
        print(f"\nWallet telah disimpan ke file keystore: {keystore_file}")

if __name__ == '__main__':
    main()
